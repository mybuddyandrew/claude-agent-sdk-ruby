require "spec_helper"
require "skein/event_store"
require "skein/task"

RSpec.describe Skein::Task do
  before do
    @db = create_test_db
    @events = Skein::EventStore.new(@db)
    @task = Skein::Task.new(db: @db, event_store: @events)
  end

  it "create returns id" do
    id = @task.create(source: "telegram", chat_id: "123", input_text: "hello")
    expect(id).to be_a(Integer)
    expect(id).to be > 0
  end

  it "create sets defaults" do
    id = @task.create(source: "telegram")
    t = @task.find(id)
    expect(t["state"]).to eq("new")
    expect(t["lane"]).to eq(1)
    expect(t["source"]).to eq("telegram")
    expect(t["requires_approval"]).to eq(0)
    expect(t["approved"]).to be_nil
  end

  it "create logs event" do
    id = @task.create(source: "heartbeat", lane: 0)
    events = @events.for_task(id)
    expect(events.size).to eq(1)
    expect(events[0]["type"]).to eq("task_created")
    expect(events[0]["payload"]["source"]).to eq("heartbeat")
    expect(events[0]["payload"]["lane"]).to eq(0)
  end

  it "new to running" do
    id = @task.create(source: "telegram")
    @task.transition!(id, "running")
    expect(@task.find(id)["state"]).to eq("running")
  end

  it "new to scheduled" do
    id = @task.create(source: "telegram")
    @task.transition!(id, "scheduled")
    expect(@task.find(id)["state"]).to eq("scheduled")
  end

  it "new to failed" do
    id = @task.create(source: "telegram")
    @task.transition!(id, "failed", error_message: "boom")
    t = @task.find(id)
    expect(t["state"]).to eq("failed")
    expect(t["error_message"]).to eq("boom")
  end

  it "running to completed" do
    id = @task.create(source: "telegram")
    @task.transition!(id, "running")
    @task.transition!(id, "completed", result_text: "done")
    t = @task.find(id)
    expect(t["state"]).to eq("completed")
    expect(t["result_text"]).to eq("done")
  end

  it "running to blocked" do
    id = @task.create(source: "telegram")
    @task.transition!(id, "running")
    @task.transition!(id, "blocked", requires_approval: 1)
    t = @task.find(id)
    expect(t["state"]).to eq("blocked")
    expect(t["requires_approval"]).to eq(1)
  end

  it "blocked to running" do
    id = @task.create(source: "telegram")
    @task.transition!(id, "running")
    @task.transition!(id, "blocked")
    @task.transition!(id, "running", approved: 1)
    t = @task.find(id)
    expect(t["state"]).to eq("running")
    expect(t["approved"]).to eq(1)
  end

  it "failed to new retry" do
    id = @task.create(source: "telegram")
    @task.transition!(id, "failed")
    @task.transition!(id, "new")
    expect(@task.find(id)["state"]).to eq("new")
  end

  it "new to completed raises" do
    id = @task.create(source: "telegram")
    expect { @task.transition!(id, "completed") }.to raise_error(Skein::Task::InvalidTransition)
  end

  it "completed to running raises" do
    id = @task.create(source: "telegram")
    @task.transition!(id, "running")
    @task.transition!(id, "completed")
    expect { @task.transition!(id, "running") }.to raise_error(Skein::Task::InvalidTransition)
  end

  it "new to blocked raises" do
    id = @task.create(source: "telegram")
    expect { @task.transition!(id, "blocked") }.to raise_error(Skein::Task::InvalidTransition)
  end

  it "transition logs event" do
    id = @task.create(source: "telegram")
    @task.transition!(id, "running")
    events = @events.for_task(id)
    expect(events.size).to eq(2)
    expect(events[1]["type"]).to eq("task_state_changed")
    expect(events[1]["payload"]["from"]).to eq("new")
    expect(events[1]["payload"]["to"]).to eq("running")
  end

  it "in_state returns matching" do
    id1 = @task.create(source: "telegram")
    @task.create(source: "telegram")
    @task.transition!(id1, "running")
    running = @task.in_state("running")
    expect(running.size).to eq(1)
    expect(running[0]["id"]).to eq(id1)
  end

  it "in_state multiple states" do
    @task.create(source: "telegram")
    id2 = @task.create(source: "telegram")
    @task.transition!(id2, "running")
    @task.transition!(id2, "completed")
    results = @task.in_state("new", "completed")
    expect(results.size).to eq(2)
  end

  it "in_state orders by lane then id" do
    id1 = @task.create(source: "telegram", lane: 1)
    id2 = @task.create(source: "heartbeat", lane: 0)
    results = @task.in_state("new")
    expect(results[0]["id"]).to eq(id2)
    expect(results[1]["id"]).to eq(id1)
  end

  it "find nonexistent returns nil" do
    expect(@task.find(999)).to be_nil
  end

  it "unknown attrs ignored" do
    id = @task.create(source: "telegram")
    @task.transition!(id, "running", bogus_field: "hack")
    expect(@task.find(id)["state"]).to eq("running")
  end

  it "next_actionable returns first new task" do
    id1 = @task.create(source: "telegram", lane: 1)
    @task.create(source: "telegram", lane: 1)
    result = @task.next_actionable
    expect(result["id"]).to eq(id1)
  end

  it "next_actionable prefers lower lane" do
    @task.create(source: "telegram", lane: 1)
    id2 = @task.create(source: "heartbeat", lane: 0)
    result = @task.next_actionable
    expect(result["id"]).to eq(id2)
  end

  it "next_actionable filters by lane" do
    @task.create(source: "telegram", lane: 1)
    id2 = @task.create(source: "heartbeat", lane: 0)
    result = @task.next_actionable(lane: 0)
    expect(result["id"]).to eq(id2)
    result_l1 = @task.next_actionable(lane: 1)
    expect(result_l1).not_to be_nil
    expect(result_l1["id"]).not_to eq(id2)
  end

  it "next_actionable skips parent with pending subtasks" do
    parent_id = @task.create(source: "telegram", lane: 1, input_text: "parent")
    @task.transition!(parent_id, "running")
    @task.transition!(parent_id, "waiting_for_input")
    sub_id = @task.create(
      source: "telegram", lane: 1, input_text: "subtask",
      parent_task_id: parent_id, subtask_index: 0
    )
    @task.create(source: "telegram", lane: 1, input_text: "standalone")
    result = @task.next_actionable
    expect(result["id"]).to eq(sub_id)
  end

  it "next_actionable returns nil when empty" do
    expect(@task.next_actionable).to be_nil
  end
end
