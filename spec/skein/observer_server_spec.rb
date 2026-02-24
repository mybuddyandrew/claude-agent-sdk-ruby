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
    expect(snapshot[:recent_memories].size).to eq(1)
    expect(snapshot[:recent_lessons].size).to eq(1)
    expect(snapshot[:recent_memories].first["content"]).to eq("User likes Ruby")
    expect(snapshot[:recent_lessons].first["content"]).to eq("Be concise")
  end

  it "parses JSON event payloads" do
    snapshot = @server.send(:build_snapshot, db: @db, limit: 5)

    expect(snapshot[:recent_events].first["payload"]).to eq({ "to" => "running" })
  end

  it "builds chat state including active runs and approvals" do
    lock = @server.instance_variable_get(:@lock)
    runs = @server.instance_variable_get(:@runs)
    active = @server.instance_variable_get(:@active_task_by_chat)
    pending = @server.instance_variable_get(:@pending_approvals)

    lock.synchronize do
      runs[42] = {
        task_id: 42,
        chat_id: "chat-1",
        input: "hello",
        status: "running",
        stream_text: "thinking",
        started_at: Time.now.utc.iso8601,
      }
      active["chat-1"] = 42
      pending[7] = {
        id: 7,
        chat_id: "chat-1",
        task_id: 42,
        tool_name: "Bash",
        tool_input: { "command" => "ls" },
      }
    end

    state = @server.send(:build_chat_state, db: @db, chat_id: "chat-1", limit: 20)

    expect(state[:turns].size).to eq(1)
    expect(state[:active_run][:task_id]).to eq(42)
    expect(state[:active_run][:status]).to eq("running")
    expect(state[:pending_approvals].size).to eq(1)
    expect(state[:pending_approvals].first[:tool_name]).to eq("Bash")
  end

  it "builds run timeline for a task" do
    task_id = @db.get_first_row("SELECT id FROM tasks LIMIT 1")["id"]

    timeline = @server.send(:build_run_timeline, db: @db, task_id: task_id, limit: 50)

    expect(timeline[:task]["id"]).to eq(task_id)
    expect(timeline[:steps]).not_to be_empty
    labels = timeline[:steps].map { |s| s[:label] }
    expect(labels).to include("Task created")
    expect(labels).to include("task_state_changed")
  end

  it "returns nil timeline for unknown task" do
    timeline = @server.send(:build_run_timeline, db: @db, task_id: 999_999, limit: 50)

    expect(timeline).to be_nil
  end

  it "falls back to raw payload for invalid JSON" do
    row = { "id" => 1, "payload" => "not-json" }
    parsed = @server.send(:parse_event_row, row)

    expect(parsed["payload"]).to eq("not-json")
  end
end
