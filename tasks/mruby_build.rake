load "#{MRUBY_ROOT}/tasks/mruby_build_gem.rake"
load "#{MRUBY_ROOT}/tasks/mruby_build_commands.rake"

module MRuby
  class << self
    def targets
      @targets ||= {}
    end

    def each_target(&block)
      @targets.each do |key, target|
        target.instance_eval(&block)
      end
    end
  end

  class Toolchain
    class << self
      attr_accessor :toolchains
    end

    def initialize(name, &block)
      @name, @initializer = name.to_s, block
      MRuby::Toolchain.toolchains ||= {}
      MRuby::Toolchain.toolchains[@name] = self
    end

    def setup(conf)
      conf.instance_eval(&@initializer)
    end

    def self.load
      Dir.glob("#{MRUBY_ROOT}/tasks/toolchains/*.rake").each do |file|
        Kernel.load file
      end
    end
  end
  Toolchain.load

  class Build
    class << self
      attr_accessor :current
    end
    include Rake::DSL
    include LoadGems
    attr_accessor :name, :bins, :exts, :file_separator, :build_dir, :gem_clone_dir
    attr_reader :libmruby, :gems
    attr_writer :enable_bintest

    COMPILERS = %w(cc cxx objc asm)
    COMMANDS = COMPILERS + %w(linker archiver yacc gperf git exts mrbc)
    attr_block MRuby::Build::COMMANDS

    Exts = Struct.new(:object, :executable, :library)

    def initialize(name='host', build_dir=nil, &block)
      @name = name.to_s

      unless MRuby.targets[@name]
        if ENV['OS'] == 'Windows_NT'
          @exts = Exts.new('.o', '.exe', '.a')
        else
          @exts = Exts.new('.o', '', '.a')
        end

        build_dir = build_dir || ENV['MRUBY_BUILD_DIR'] || "#{MRUBY_ROOT}/build"

        @file_separator = '/'
        @build_dir = "#{build_dir}/#{@name}"
        @gem_clone_dir = "#{build_dir}/mrbgems"
        @cc = Command::Compiler.new(self, %w(.c))
        @cxx = Command::Compiler.new(self, %w(.cc .cxx .cpp))
        @objc = Command::Compiler.new(self, %w(.m))
        @asm = Command::Compiler.new(self, %w(.S .asm))
        @linker = Command::Linker.new(self)
        @archiver = Command::Archiver.new(self)
        @yacc = Command::Yacc.new(self)
        @gperf = Command::Gperf.new(self)
        @git = Command::Git.new(self)
        @mrbc = Command::Mrbc.new(self)

        @bins = %w(mrbc)
        @gems, @libmruby = MRuby::Gem::List.new, []
        @build_mrbtest_lib_only = false
        @cxx_abi_enabled = false
        @cxx_exception_disabled = false

        MRuby.targets[@name] = self
      end

      MRuby::Build.current = MRuby.targets[@name]
      MRuby.targets[@name].instance_eval(&block)
    end

    def enable_debug
      compilers.each { |c| c.defines += %w(MRB_DEBUG) }
      @mrbc.compile_options += ' -g'
    end

    def disable_cxx_exception
      @cxx_exception_disabled = true
    end

    def cxx_abi_enabled?
      @cxx_abi_enabled
    end

    def enable_cxx_abi
      return if @cxx_exception_disabled or @cxx_abi_enabled
      compilers.each { |c| c.defines += %w(MRB_ENABLE_CXX_EXCEPTION) }
      linker.command = cxx.command
      @cxx_abi_enabled = true
    end

    def enable_bintest
      @enable_bintest = true
    end

    def bintest_enabled?
      @enable_bintest
    end

    def toolchain(name)
      tc = Toolchain.toolchains[name.to_s]
      fail "Unknown #{name} toolchain" unless tc
      tc.setup(self)
    end

    def root
      MRUBY_ROOT
    end

    def mrbcfile
      MRuby.targets[@name].exefile("#{MRuby.targets[@name].build_dir}/bin/mrbc")
    end

    def compilers
      COMPILERS.map do |c|
        instance_variable_get("@#{c}")
      end
    end

    def define_rules
      compilers.each do |compiler|
        if respond_to?(:enable_gems?) && enable_gems?
          compiler.defines -= %w(DISABLE_GEMS)
        else
          compiler.defines += %w(DISABLE_GEMS)
        end
        compiler.define_rules build_dir, File.expand_path(File.join(File.dirname(__FILE__), '..'))
      end
    end

    def filename(name)
      if name.is_a?(Array)
        name.flatten.map { |n| filename(n) }
      else
        '"%s"' % name.gsub('/', file_separator)
      end
    end

    def cygwin_filename(name)
      if name.is_a?(Array)
        name.flatten.map { |n| cygwin_filename(n) }
      else
        '"%s"' % `cygpath -w "#{filename(name)}"`.strip
      end
    end

    def exefile(name)
      if name.is_a?(Array)
        name.flatten.map { |n| exefile(n) }
      else
        "#{name}#{exts.executable}"
      end
    end

    def objfile(name)
      if name.is_a?(Array)
        name.flatten.map { |n| objfile(n) }
      else
        "#{name}#{exts.object}"
      end
    end

    def libfile(name)
      if name.is_a?(Array)
        name.flatten.map { |n| libfile(n) }
      else
        "#{name}#{exts.library}"
      end
    end

    def build_mrbtest_lib_only
      @build_mrbtest_lib_only = true
    end

    def build_mrbtest_lib_only?
      @build_mrbtest_lib_only
    end

    def run_test
      puts ">>> Test #{name} <<<"
      mrbtest = exefile("#{build_dir}/test/mrbtest")
      sh "#{filename mrbtest.relative_path}#{$verbose ? ' -v' : ''}"
      puts
      run_bintest if @enable_bintest
    end

    def run_bintest
      targets = @gems.select { |v| File.directory? "#{v.dir}/bintest" }.map { |v| filename v.dir }
      sh "ruby test/bintest.rb #{targets.join ' '}"
    end

    def print_build_summary
      puts "================================================"
      puts "      Config Name: #{@name}"
      puts " Output Directory: #{self.build_dir.relative_path}"
      puts "         Binaries: #{@bins.join(', ')}" unless @bins.empty?
      unless @gems.empty?
        puts "    Included Gems:"
        @gems.map do |gem|
          gem_version = " - #{gem.version}" if gem.version != '0.0.0'
          gem_summary = " - #{gem.summary}" if gem.summary
          puts "             #{gem.name}#{gem_version}#{gem_summary}"
          puts "               - Binaries: #{gem.bins.join(', ')}" unless gem.bins.empty?
        end
      end
      puts "================================================"
      puts
    end
  end # Build

  class CrossBuild < Build
    attr_block %w(test_runner)

    def initialize(name, build_dir=nil, &block)
      @test_runner = Command::CrossTestRunner.new(self)
      super
    end

    def mrbcfile
      MRuby.targets['host'].exefile("#{MRuby.targets['host'].build_dir}/bin/mrbc")
    end

    def run_test
      mrbtest = exefile("#{build_dir}/test/mrbtest")
      if (@test_runner.command == nil)
        puts "You should run #{mrbtest} on target device."
        puts
      else
        @test_runner.run(mrbtest)
      end
    end
  end # CrossBuild
end # MRuby
