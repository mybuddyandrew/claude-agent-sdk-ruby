require "spec_helper"
require "tmpdir"
require "fileutils"
require "skein/memory"
require "skein/timer"
require "skein/event_store"
require "skein/tool_executor"
require "skein/tools/remember"
require "skein/tools/recall"
require "skein/tools/send_telegram"
require "skein/tools/create_reminder"
require "skein/tools/write_note"

RSpec.describe Skein::ToolExecutor do
  before do
    @db = Skein::DB.new(":memory:")
    @events = Skein::EventStore.new(@db)
    @memory = Skein::Memory.new(db: @db, event_store: @events)
    @timers = Skein::Timer.new(db: @db, event_store: @events)
    @executor = Skein::ToolExecutor.new(memory: @memory, timers: @timers)
  end

  it "known tools" do
    expect(@executor.known_tool?("skein_remember")).to be_truthy
    expect(@executor.known_tool?("skein_recall")).to be_truthy
    expect(@executor.known_tool?("skein_send_telegram")).to be_truthy
    expect(@executor.known_tool?("skein_create_reminder")).to be_truthy
    expect(@executor.known_tool?("skein_write_note")).to be_truthy
    expect(@executor.known_tool?("unknown_tool")).to be_falsey
    expect(@executor.known_tool?("remember")).to be_falsey
  end

  it "approval required" do
    expect(@executor.requires_approval?("skein_send_telegram")).to be_truthy
    expect(@executor.requires_approval?("skein_create_reminder")).to be_truthy
    expect(@executor.requires_approval?("skein_write_note")).to be_truthy
    expect(@executor.requires_approval?("skein_remember")).to be_falsey
    expect(@executor.requires_approval?("skein_recall")).to be_falsey
  end

  it "execute remember" do
    result = @executor.execute(
      "skein_remember",
      { "content" => "User likes Ruby", "category" => "preference" },
      chat_id: "test", task_id: nil
    )
    expect(result).to match(/Remembered/)
    expect(@memory.count).to eq(1)
  end

  it "execute recall empty" do
    result = @executor.execute("skein_recall", { "query" => "nonexistent" }, chat_id: "test")
    expect(result).to match(/No memories found/)
  end

  it "execute recall with results" do
    @memory.store(content: "User prefers dark mode", category: "preference")
    result = @executor.execute("skein_recall", { "query" => "dark mode" }, chat_id: "test")
    expect(result).to match(/dark mode/)
    expect(result).to match(/1 memories found/)
  end

  it "execute create reminder" do
    result = @executor.execute(
      "skein_create_reminder",
      { "text" => "Buy groceries", "fire_at" => "2026-12-25T10:00:00Z" },
      chat_id: "test"
    )
    expect(result).to match(/Reminder created/)
    expect(result).to match(/Buy groceries/)
  end

  it "execute write note" do
    tmp_dir = File.join(Dir.tmpdir, "skein-test-notes-#{$$}")
    config = Struct.new(:notes_dir).new(tmp_dir)
    executor = Skein::ToolExecutor.new(memory: @memory, timers: @timers, config: config)
    result = executor.execute(
      "skein_write_note",
      { "title" => "Test Note", "content" => "Some content here" },
      chat_id: "test"
    )
    expect(result).to match(/Note saved/)
    files = Dir.glob(File.join(tmp_dir, "*test-note*"))
    expect(files.size).to eq(1)
    expect(File.read(files.first)).to match(/# Test Note/)
  ensure
    FileUtils.rm_rf(tmp_dir) if tmp_dir && Dir.exist?(tmp_dir)
  end

  it "execute unknown tool raises" do
    expect {
      @executor.execute("skein_unknown", {}, chat_id: "test")
    }.to raise_error(KeyError)
  end

  it "execute send telegram" do
    sent = []
    mock_telegram = Object.new
    mock_telegram.define_singleton_method(:send_message) do |chat_id:, text:|
      sent << { chat_id: chat_id, text: text }
    end
    @executor.channel_context = { telegram: mock_telegram }
    result = @executor.execute("skein_send_telegram", { "text" => "Hello from Skein" }, chat_id: "123")
    expect(result).to match(/Message sent/)
    expect(sent.size).to eq(1)
    expect(sent[0][:text]).to eq("Hello from Skein")
  end

  it "remember rejects nil content" do
    result = @executor.execute("skein_remember", { "content" => nil }, chat_id: "test")
    expect(result).to match(/Error.*required/)
    expect(@memory.count).to eq(0)
  end

  it "remember rejects empty content" do
    result = @executor.execute("skein_remember", { "content" => "" }, chat_id: "test")
    expect(result).to match(/Error.*required/)
  end

  it "send telegram rejects nil text" do
    mock_telegram = Object.new
    @executor.channel_context = { telegram: mock_telegram }
    result = @executor.execute("skein_send_telegram", {}, chat_id: "test")
    expect(result).to match(/Error.*required/)
  end

  it "write note rejects nil title" do
    result = @executor.execute("skein_write_note", { "title" => nil, "content" => "some text" }, chat_id: "test")
    expect(result).to match(/Error.*title.*required/)
  end

  it "create reminder rejects invalid fire_at" do
    result = @executor.execute("skein_create_reminder", { "text" => "test", "fire_at" => "not-a-date" }, chat_id: "test")
    expect(result).to match(/Error.*invalid fire_at/)
  end

  it "create reminder rejects missing text" do
    result = @executor.execute("skein_create_reminder", { "fire_at" => "2026-12-25T10:00:00Z" }, chat_id: "test")
    expect(result).to match(/Error.*text.*required/)
  end

  it "channel context can be updated" do
    mock_telegram = Object.new
    # channel_context= is a writer; just verify it doesn't raise
    expect { @executor.channel_context = { telegram: mock_telegram } }.not_to raise_error
  end
end
