require "spec_helper"
require "skein/event_store"

RSpec.describe Skein::EventStore do
  before do
    @db = create_test_db
    @events = Skein::EventStore.new(@db)
  end

  it "append returns an id" do
    id = @events.append(type: "test", payload: { foo: "bar" })
    expect(id).to be_a(Integer)
    expect(id).to be > 0
  end

  it "append stores event" do
    @events.append(type: "test_event", payload: { key: "value" })
    row = @db.get_first_row("SELECT * FROM events WHERE type = ?", ["test_event"])
    expect(row["type"]).to eq("test_event")
    expect(row["task_id"]).to be_nil
    expect(row["payload"]).to eq('{"key":"value"}')
  end

  it "append with task_id" do
    @db.execute("INSERT INTO tasks (source) VALUES (?)", ["test"])
    task_id = @db.last_insert_row_id
    @events.append(type: "linked", payload: {}, task_id: task_id)
    row = @db.get_first_row("SELECT * FROM events WHERE type = ?", ["linked"])
    expect(row["task_id"]).to eq(task_id)
  end

  it "for_task returns ordered events" do
    @db.execute("INSERT INTO tasks (source) VALUES (?)", ["test"])
    task_id = @db.last_insert_row_id
    @events.append(type: "first", payload: { n: 1 }, task_id: task_id)
    @events.append(type: "second", payload: { n: 2 }, task_id: task_id)
    @events.append(type: "unrelated", payload: {})
    result = @events.for_task(task_id)
    expect(result.size).to eq(2)
    expect(result[0]["type"]).to eq("first")
    expect(result[1]["type"]).to eq("second")
    expect(result[0]["payload"]).to eq({ "n" => 1 })
  end

  it "recent returns newest first" do
    3.times { |i| @events.append(type: "tick", payload: { n: i }) }
    result = @events.recent(type: "tick", limit: 2)
    expect(result.size).to eq(2)
    expect(result[0]["payload"]).to eq({ "n" => 2 })
    expect(result[1]["payload"]).to eq({ "n" => 1 })
  end

  it "recent with no matches" do
    result = @events.recent(type: "nonexistent", limit: 5)
    expect(result).to be_empty
  end

  it "count" do
    expect(@events.count).to eq(0)
    3.times { |i| @events.append(type: "tick", payload: { n: i }) }
    expect(@events.count).to eq(3)
  end

  it "prune deletes old events" do
    @events.append(type: "old", payload: {})
    @db.execute(
      "UPDATE events SET created_at = ? WHERE type = 'old'",
      [(Time.now.utc - 60 * 86400).strftime("%Y-%m-%dT%H:%M:%S")]
    )
    @events.append(type: "recent", payload: {})
    pruned = @events.prune!(days: 30)
    expect(pruned).to eq(1)
    expect(@events.count).to eq(1)
    remaining = @events.recent(type: "recent", limit: 1)
    expect(remaining.size).to eq(1)
  end

  it "prune keeps recent events" do
    3.times { @events.append(type: "fresh", payload: {}) }
    pruned = @events.prune!(days: 30)
    expect(pruned).to eq(0)
    expect(@events.count).to eq(3)
  end
end
