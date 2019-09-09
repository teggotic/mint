module Mint
  # A workspace represents a mint project where the root is the directory
  # containing the `mint.json` file.
  #
  # The workspace provides:
  # - an up to date AST of the project
  # - provides packages and information
  # - emits events for changes
  class Workspace
    @@workspaces = {} of String => Workspace

    class_getter workspaces

    def self.from_file(path : String) : Workspace
      new(root_from_file(path))
    end

    def self.current : Workspace
      new(Dir.current)
    end

    def self.root_from_file(path : String) : String
      root = File.dirname(path)

      loop do
        raise "Invalid workspace!" if root == "." || root == "/"

        if File.exists?(File.join(root, "mint.json"))
          break
        else
          root = File.dirname(root)
        end
      end

      root
    end

    def self.[](path)
      root = root_from_file(path)

      @@workspaces[root] ||= begin
        workspace = Workspace.new(root)
        workspace.update_cache
        workspace.watch
        workspace
      end
    end

    alias ChangeProc = Proc(Ast | Error, Nil)

    @event_handlers = {} of String => Array(ChangeProc)
    @cache = {} of String => Ast
    @pattern = [] of String

    getter type_checker : TypeChecker
    getter error : Error | Nil
    getter json : MintJson
    getter root : String
    getter cache : Hash(String, Ast)

    property format : Bool = false

    def initialize(@root : String)
      json_path =
        File.join(@root, "mint.json")

      @json =
        MintJson.from_file(json_path)

      @json_watcher =
        Watcher.new([json_path])

      @source_watcher =
        Watcher.new(all_files_pattern)

      @static_watcher =
        Watcher.new(all_static_pattern)

      @type_checker =
        TypeChecker.new(Ast.new)
    end

    def on(event, &handler : ChangeProc)
      @event_handlers[event] ||= [] of ChangeProc
      @event_handlers[event] << handler
    end

    def packages : Array(Workspace)
      pattern =
        File.join(root, ".mint/packages/**/mint.json")

      Dir.glob(pattern).map do |file|
        Workspace.from_file(file)
      end
    end

    def ast
      @cache
        .values
        .reduce(Ast.new) { |memo, item| memo.merge item }
        .merge(Core.ast)
    end

    def initialize_cache
      files = self.files
      files.each_with_index do |file, index|
        @cache[file] ||= Parser.parse(file)

        yield file, index, files.size
      end
    end

    def watch
      spawn do
        # Watches static files
        @static_watcher.watch do
          call "change", ast
        end
      end

      spawn do
        # Watches all the `*.mint` files
        @source_watcher.watch do |files|
          # Remove the changed files from the cache
          files.each { |file| @cache.delete(file) }

          # Update the cache
          update_cache
        end
      end

      spawn do
        # Watches the `mint.json` file
        @json_watcher.watch do
          # We need to update the patterns because:
          # 1. packages could have been added or removed
          # 2. source directories could have been added or removed
          update_patterns

          # Reset the cache, this will cause a full recompilation, in the
          # future this could be changed to only remove files from the cache
          # that have been changed.
          reset_cache
        end
      end
    end

    def files
      Dir.glob(all_files_pattern)
    end

    def files_pattern : Array(String)
      json
        .source_directories
        .map { |dir| File.join(root, dir, "/**/*.mint") }
    end

    def static_pattern : Array(String)
      json
        .external_javascripts
    end

    def update_cache
      files.each do |file|
        path = File.real_path(file)

        @cache[path] ||= begin
          process(File.read(path), path)
        end
      end

      check!

      @error = nil

      call "change", ast
    rescue error : Error
      @error = error

      call "change", error
    end

    def update(contents, file)
      @cache[file] = process(contents, file)
      puts @cache.keys.inspect, file.inspect
      check!
      @error = nil
    rescue error : Error
      puts error
      @error = error
    end

    private def process(contents, file)
      ast = Parser.parse(contents, File.real_path(file))

      if format
        formatted =
          Formatter
            .new(ast, json.formatter_config)
            .format

        if formatted != File.read(file)
          File.write(file, formatted)
        end
      end

      ast
    end

    private def check!
      @type_checker = Mint::TypeChecker.new(ast, check_env: false)
      @type_checker.check
    end

    private def call(event, arg)
      @event_handlers[event]?.try(&.each(&.call(arg)))
    end

    private def reset_cache
      @cache = {} of String => Ast
      update_cache
    end

    private def update_patterns
      @static_watcher.pattern = all_static_pattern
      @source_watcher.pattern = all_files_pattern
    end

    private def all_static_pattern : Array(String)
      packages
        .map(&.static_pattern)
        .flatten
        .concat(static_pattern)
    end

    private def all_files_pattern : Array(String)
      packages
        .map(&.files_pattern)
        .flatten
        .concat(files_pattern)
    end
  end
end
