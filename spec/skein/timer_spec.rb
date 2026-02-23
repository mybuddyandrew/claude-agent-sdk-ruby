require "spec_helper"
require "skein/event_store"
require "skein/timer"

RSpec.describe Skein::Timer do
  before do
    @db = create_test_db
    @events = Skein::EventStore.new(@db)
    @timer = Skein::Timer.new(db: @db, event_store: @events)
  end

  it "create returns id" do
    id = @timer.create(name: "test", next_fire_at: Time.now.utc + 3600)
    expect(id).to be_a(Integer)
    expect(id).to be > 0
  end

  it "create stores timer" do
    @timer.create(name: "heartbeat", next_fire_at: Time.now.utc + 3600, interval_seconds: 3600)
    row = @timer.find_by_name("heartbeat")
    expect(row["name"]).to eq("heartbeat")
    expect(row["interval_seconds"]).to eq(3600)
    expect(row["enabled"]).to eq(1)
  end

  it "create logs event" do
    @timer.create(name: "test", next_fire_at: Time.now.utc + 60)
    events = @events.recent(type: "timer_created", limit: 1)
    expect(events.size).to eq(1)
    expect(events[0]["payload"]["name"]).to eq("test")
  end

  it "create upserts by name" do
    @timer.create(name: "heartbeat", next_fire_at: Time.now.utc + 3600, interval_seconds: 3600)
    @timer.create(name: "heartbeat", next_fire_at: Time.now.utc + 7200, interval_seconds: 1800)
    row = @timer.find_by_name("heartbeat")
    expect(row["interval_seconds"]).to eq(1800)
    count = @db.execute("SELECT COUNT(*) as c FROM timers WHERE name = ?", ["heartbeat"])
    expect(count[0]["c"]).to eq(1)
  end

  it "due_timers returns past due" do
    @timer.create(name: "past", next_fire_at: Time.now.utc - 60)
    @timer.create(name: "future", next_fire_at: Time.now.utc + 3600)
    due = @timer.due_timers
    expect(due.size).to eq(1)
    expect(due[0]["name"]).to eq("past")
  end

  it "due_timers skips disabled" do
    @timer.create(name: "disabled", next_fire_at: Time.now.utc - 60)
    @db.execute("UPDATE timers SET enabled = 0 WHERE name = ?", ["disabled"])
    expect(@timer.due_timers).to be_empty
  end

  it "due_timers parses payload" do
    @timer.create(name: "reminder", next_fire_at: Time.now.utc - 60, payload: { text: "hello" })
    due = @timer.due_timers
    expect(due[0]["payload"]).to eq({ "text" => "hello" })
  end

  it "mark_fired advances recurring" do
    @timer.create(name: "heartbeat", next_fire_at: Time.now.utc - 60, interval_seconds: 3600)
    due = @timer.due_timers
    expect(due.size).to eq(1)
    @timer.mark_fired!(due[0]["id"])
    expect(@timer.due_timers).to be_empty
    row = @timer.find_by_name("heartbeat")
    expect(row["enabled"]).to eq(1)
  end

  it "mark_fired disables oneshot" do
    @timer.create(name: "reminder:1", next_fire_at: Time.now.utc - 60)
    due = @timer.due_timers
    @timer.mark_fired!(due[0]["id"])
    row = @timer.find_by_name("reminder:1")
    expect(row["enabled"]).to eq(0)
    expect(@timer.due_timers).to be_empty
  end

  it "mark_fired logs event" do
    @timer.create(name: "test", next_fire_at: Time.now.utc - 60)
    due = @timer.due_timers
    @timer.mark_fired!(due[0]["id"])
    events = @events.recent(type: "timer_fired", limit: 1)
    expect(events.size).to eq(1)
    expect(events[0]["payload"]["name"]).to eq("test")
  end

  it "due_timers ordered by fire time" do
    @timer.create(name: "second", next_fire_at: Time.now.utc - 30)
    @timer.create(name: "first", next_fire_at: Time.now.utc - 60)
    due = @timer.due_timers
    expect(due[0]["name"]).to eq("first")
    expect(due[1]["name"]).to eq("second")
  end
end
