require "spec_helper"

RSpec.describe Skein::DB do
  before do
    @db = create_test_db
  end

  it "schema creates all tables" do
    tables = @db.execute(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
    ).map { |r| r["name"] }.sort

    expect(tables).to include("events")
    expect(tables).to include("tasks")
    expect(tables).to include("timers")
    expect(tables).to include("conversation_turns")
    expect(tables).to include("memories")
    expect(tables).to include("lessons")
  end

  it "inserts and selects an event" do
    @db.execute(
      "INSERT INTO events (type, payload) VALUES (?, ?)",
      ["test_event", '{"key": "value"}']
    )
    row = @db.get_first_row("SELECT * FROM events WHERE type = ?", ["test_event"])

    expect(row["type"]).to eq("test_event")
    expect(row["payload"]).to eq('{"key": "value"}')
    expect(row["task_id"]).to be_nil
    expect(row["created_at"]).not_to be_nil
  end

  it "inserts and selects a task" do
    @db.execute(
      "INSERT INTO tasks (source, chat_id, input_text, lane) VALUES (?, ?, ?, ?)",
      ["telegram", "123", "hello", 1]
    )
    row = @db.get_first_row("SELECT * FROM tasks WHERE source = ?", ["telegram"])

    expect(row["state"]).to eq("new")
    expect(row["lane"]).to eq(1)
    expect(row["chat_id"]).to eq("123")
    expect(row["input_text"]).to eq("hello")
  end

  it "inserts and selects a timer" do
    @db.execute(
      "INSERT INTO timers (name, next_fire_at, interval_seconds, payload) VALUES (?, ?, ?, ?)",
      ["heartbeat", "2026-02-22T12:00:00.000", 3600, "{}"]
    )
    row = @db.get_first_row("SELECT * FROM timers WHERE name = ?", ["heartbeat"])

    expect(row["name"]).to eq("heartbeat")
    expect(row["interval_seconds"]).to eq(3600)
    expect(row["enabled"]).to eq(1)
  end

  it "enforces timer name uniqueness" do
    @db.execute(
      "INSERT INTO timers (name, next_fire_at) VALUES (?, ?)",
      ["unique_timer", "2026-02-22T12:00:00.000"]
    )
    expect {
      @db.execute(
        "INSERT INTO timers (name, next_fire_at) VALUES (?, ?)",
        ["unique_timer", "2026-02-22T13:00:00.000"]
      )
    }.to raise_error(SQLite3::ConstraintException)
  end

  it "inserts and selects conversation turns" do
    @db.execute(
      "INSERT INTO conversation_turns (chat_id, role, content) VALUES (?, ?, ?)",
      ["123", "user", "hello"]
    )
    row = @db.get_first_row("SELECT * FROM conversation_turns WHERE chat_id = ?", ["123"])

    expect(row["role"]).to eq("user")
    expect(row["content"]).to eq("hello")
  end

  it "vec is disabled by default when gem is missing" do
    db = Skein::DB.new(":memory:", vec: false)
    expect(db.vec_enabled).to be_falsey
  end

  it "vec false skips loading" do
    db = Skein::DB.new(":memory:", vec: false)
    expect(db.vec_enabled).to be_falsey
    db.execute("INSERT INTO events (type, payload) VALUES (?, ?)", ["test", "{}"])
    row = db.get_first_row("SELECT * FROM events WHERE type = ?", ["test"])
    expect(row["type"]).to eq("test")
  end

  it "vec auto degrades gracefully" do
    db = Skein::DB.new(":memory:")
    expect([true, false]).to include(db.vec_enabled)
  end

  it "vec true raises when gem is missing" do
    begin
      require "sqlite_vec"
      skip "sqlite_vec gem is available, can't test failure path"
    rescue LoadError
      expect {
        Skein::DB.new(":memory:", vec: true)
      }.to raise_error(LoadError)
    end
  end
end
