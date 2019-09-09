require "spec"
require "diff"

MINT_ENV["TEST"] = "YES"
ERROR_MESSAGES = [] of String

class Mint::Error < Exception
  macro inherited
    name = {{@type.name.stringify.split("::").last.underscore}}

    unless ["type_error", "install_error", "syntax_error", "json_error"].includes?(name)
      ERROR_MESSAGES << name
    end
  end
end

def diff(a, b)
  file1 = File.tempfile
  file1.puts a.strip
  file1.flush
  file2 = File.tempfile
  file2.puts b
  file2.flush

  io = IO::Memory.new
  Process.run("git", ["--no-pager", "diff", "--no-index", "--color=always", file1.path, file2.path], output: io)

  file1.delete
  file2.delete

  io.to_s
end

require "../src/all"

# Mock things
class Mint::Installer::Repository
  @terminal = Render::Terminal.new

  def terminal
    @terminal
  end

  def output
    terminal.io.to_s.uncolorize
  end

  def run(command, chdir = directory)
    content =
      case command.split(" ")[1]
      when "tag"
        "0.1.0\n0.2.0"
      when "fetch"
        "fetched"
      when "checkout"
        "checked out"
      when "clone"
        "cloned"
      else
        ""
      end

    if url == "error"
      {Process::Status.new(1), "", content}
    else
      {Process::Status.new(0), content, ""}
    end
  end
end

macro subject(method)
  subject = ->(sample : String) {
    Mint::Parser.new(sample, "TestFile.mint").{{method}}
  }
end

macro expect_ok(sample)
  it "Parses: " + {{"#{sample}"}} do
    result = subject.call({{sample}})
    result.should_not be_nil
    result.should be_a(Mint::Ast::Node)
  end
end

macro expect_ignore(sample)
  it {{"#{sample}"}} do
    subject.call({{sample}}).should be_nil
  end
end

macro expect_error(sample, error)
  it {{"#{sample}"}} do
    expect_raises({{error}}) do
      subject.call({{sample}})
    end
  end
end

class Workspace
  @id : String
  @files : Hash(String, File) = {} of String => File

  def workspace
    Mint::Workspace[File.join(@root, "test.file")]
  end

  def initialize
    @id =
      Random.new.hex(5)

    @root =
      File.join(Dir.tempdir, @id)

    Dir.mkdir(@root)

    file("mint.json", {
      "name"               => "test",
      "source-directories" => [
        ".",
      ],
    }.to_json)
  end

  def file(name, contents) : File
    file =
      File.new(File.join(@root, name), "w+")

    file.print(contents)
    file.flush

    @files[name] = file

    file
  end

  def file_path(name)
    "file://" + @files[name]?.try(&.path).to_s
  end

  def cleanup
    @files.values.each(&.delete)
    Dir.rmdir(@root)
  end
end

def with_workspace
  workspace = Workspace.new

  begin
    yield workspace
  ensure
    workspace.cleanup
  end
end

def notify_lsp(method, message)
  in_io =
    IO::Memory.new

  out_io =
    IO::Memory.new

  server =
    Mint::LS::Server.new(in_io, out_io)

  body = {
    jsonrpc: "2.0",
    params:  message,
    method:  method,
  }.to_json

  in_io.print "Content-Length: #{body.bytesize}\r\n\r\n#{body}"
  in_io.rewind

  server.read
end

def expect_lsp(id, method, message, expected)
  in_io =
    IO::Memory.new

  out_io =
    IO::Memory.new

  server =
    Mint::LS::Server.new(in_io, out_io)

  body = {
    jsonrpc: "2.0",
    id:      id,
    params:  message,
    method:  method,
  }.to_json

  in_io.print "Content-Length: #{body.bytesize}\r\n\r\n#{body}"
  in_io.rewind

  server.read

  result =
    LSP::MessageParser
      .parse(out_io.rewind)
      .to_pretty_json

  expected =
    expected.to_pretty_json

  begin
    result.should eq(expected)
  rescue error
    fail diff(expected, result)
  end
end
