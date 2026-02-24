require "spec_helper"
require "skein/config"
require "skein/observer_server"

RSpec.describe Skein::ObserverServer do
  before do
    @db = create_test_db(vec: false)
    @db.execute(
      "INSERT INTO tasks (state, source, lane, chat_id, input_text) VALUES (?, ?, ?, ?, ?)",
      ["running", "cli", 1, "chat-1", "do the thing"]
    )
    task_id = @db.last_insert_row_id
    @db.execute(
      "INSERT INTO events (type, task_id, payload) VALUES (?, ?, ?)",
      ["task_state_changed", task_id, '{"to":"running"}']
    )
    @db.execute(
      "INSERT INTO conversation_turns (chat_id, role, content, task_id) VALUES (?, ?, ?, ?)",
      ["chat-1", "assistant", "working on it", task_id]
    )
    @db.execute("INSERT INTO memories (content, source) VALUES (?, ?)", ["User likes Ruby", "explicit"])
    @db.execute("INSERT INTO lessons (content) VALUES (?)", ["Be concise"])
    @db.execute("INSERT INTO timers (name, next_fire_at) VALUES (?, strftime('%Y-%m-%dT%H:%M:%f','now'))", ["heartbeat"])
    @db.execute("INSERT INTO sessions (chat_id, session_id) VALUES (?, ?)", ["chat-1", "sess-1"])

    config = Skein::Config.new(db_path: "test.db", embedding_enabled: false)
    @server = described_class.new(config: config, host: "127.0.0.1", port: 4310, logger: ->(_msg) {})
  end

  it "builds a snapshot with counts and recent rows" do
    snapshot = @server.send(:build_snapshot, db: @db, limit: 20)

    expect(snapshot[:db_path]).to eq("test.db")
    expect(snapshot[:counts][:tasks]).to eq(1)
    expect(snapshot[:counts][:events]).to eq(1)
    expect(snapshot[:counts][:memories]).to eq(1)
    expect(snapshot[:counts][:lessons]).to eq(1)
    expect(snapshot[:counts][:timers]).to eq(1)
    expect(snapshot[:counts][:turns]).to eq(1)
    expect(snapshot[:counts][:sessions]).to eq(1)
    expect(snapshot[:task_state_counts]["running"]).to eq(1)
    expect(snapshot[:recent_tasks].size).to eq(1)
    expect(snapshot[:recent_events].size).to eq(1)
    expect(snapshot[:recent_turns].size).to eq(1)
  end

  it "parses JSON event payloads" do
    snapshot = @server.send(:build_snapshot, db: @db, limit: 5)

    expect(snapshot[:recent_events].first["payload"]).to eq({ "to" => "running" })
  end

  it "falls back to raw payload for invalid JSON" do
    row = { "id" => 1, "payload" => "not-json" }
    parsed = @server.send(:parse_event_row, row)

    expect(parsed["payload"]).to eq("not-json")
  end
end
