require "spec_helper"
require "open3"
require "tmpdir"
require "time"

RSpec.describe "bin/skein" do
  let(:ruby_bin) { File.expand_path("~/.asdf/shims/ruby") }
  let(:bin_path) { File.expand_path("../../bin/skein", __dir__) }
  let(:repo_root) { File.expand_path("../..", __dir__) }

  it "prints status for a populated database" do
    Dir.mktmpdir("skein-bin") do |dir|
      db_path = File.join(dir, "skein.db")
      db = Skein::DB.new(db_path, vec: false)
      db.execute("INSERT INTO tasks (source) VALUES (?)", ["test"])
      db.execute("INSERT INTO memories (content, source) VALUES (?, ?)", ["m1", "explicit"])
      db.execute("INSERT INTO lessons (content) VALUES (?)", ["l1"])
      db.execute("INSERT INTO timers (name, next_fire_at) VALUES (?, ?)", ["heartbeat", Time.now.utc.iso8601])
      db.execute("INSERT INTO conversation_turns (chat_id, role, content) VALUES (?, ?, ?)", ["c1", "user", "hi"])
      db.close

      env = {
        "SKEIN_DB_PATH" => db_path,
        "SKEIN_EMBEDDING_ENABLED" => "false",
      }
      stdout, stderr, status = Open3.capture3(env, ruby_bin, bin_path, "status", chdir: repo_root)

      expect(status.success?).to be(true)
      expect(stderr).to eq("")
      expect(stdout).to include("Skein status")
      expect(stdout).to include("tasks: 1")
      expect(stdout).to include("memories: 1")
      expect(stdout).to include("lessons: 1")
      expect(stdout).to include("timers: 1")
      expect(stdout).to include("turns: 1")
    end
  end

  it "prints usage for unknown commands" do
    _stdout, stderr, status = Open3.capture3(ruby_bin, bin_path, "wat", chdir: repo_root)

    expect(status.success?).to be(false)
    expect(stderr).to include("Usage: skein [repl|kernel|watch|ui|status|version]")
  end
end
