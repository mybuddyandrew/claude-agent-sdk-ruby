require "spec_helper"
require "skein/event_store"
require "skein/task"
require "skein/lane"

RSpec.describe Skein::Lane do
  before do
    @db = create_test_db
    @events = Skein::EventStore.new(@db)
    @task = Skein::Task.new(db: @db, event_store: @events)
    @lane = Skein::Lane.new(task: @task)
  end

  it "next_task returns nil when empty" do
    expect(@lane.next_task).to be_nil
  end

  it "next_task returns new task" do
    id = @task.create(source: "telegram", chat_id: "123", input_text: "hello")
    result = @lane.next_task
    expect(result["id"]).to eq(id)
  end

  it "next_task prefers l0 over l1" do
    @task.create(source: "telegram", lane: 1)
    l0_id = @task.create(source: "heartbeat", lane: 0)
    result = @lane.next_task
    expect(result["id"]).to eq(l0_id)
  end

  it "next_task returns oldest in same lane" do
    id1 = @task.create(source: "telegram", lane: 1)
    @task.create(source: "telegram", lane: 1)
    result = @lane.next_task
    expect(result["id"]).to eq(id1)
  end

  it "next_task skips running tasks" do
    id = @task.create(source: "telegram")
    @task.transition!(id, "running")
    expect(@lane.next_task).to be_nil
  end

  it "next_task skips completed" do
    id1 = @task.create(source: "telegram")
    @task.transition!(id1, "running")
    @task.transition!(id1, "completed")
    id2 = @task.create(source: "telegram")
    result = @lane.next_task
    expect(result["id"]).to eq(id2)
  end

  it "next_task skips blocked" do
    id1 = @task.create(source: "telegram")
    @task.transition!(id1, "running")
    @task.transition!(id1, "blocked", requires_approval: 1)
    expect(@lane.next_task).to be_nil
  end

  it "pending_approvals returns blocked tasks" do
    id = @task.create(source: "telegram", chat_id: "123")
    @task.transition!(id, "running")
    @task.transition!(id, "blocked", requires_approval: 1)
    approvals = @lane.pending_approvals
    expect(approvals.size).to eq(1)
    expect(approvals[0]["id"]).to eq(id)
  end

  it "pending_approvals filters by chat_id" do
    id1 = @task.create(source: "telegram", chat_id: "123")
    @task.transition!(id1, "running")
    @task.transition!(id1, "blocked", requires_approval: 1)
    id2 = @task.create(source: "telegram", chat_id: "456")
    @task.transition!(id2, "running")
    @task.transition!(id2, "blocked", requires_approval: 1)
    approvals = @lane.pending_approvals(chat_id: "123")
    expect(approvals.size).to eq(1)
    expect(approvals[0]["chat_id"]).to eq("123")
  end

  it "pending_approvals excludes already approved" do
    id = @task.create(source: "telegram", chat_id: "123")
    @task.transition!(id, "running")
    @task.transition!(id, "blocked", requires_approval: 1)
    @task.transition!(id, "running", approved: 1)
    approvals = @lane.pending_approvals
    expect(approvals).to be_empty
  end

  it "next_interrupt returns l0 only" do
    @task.create(source: "telegram", chat_id: "1", lane: Skein::Lane::L1_INTERACTIVE)
    l0_id = @task.create(source: "heartbeat", lane: Skein::Lane::L0_INTERRUPT)
    result = @lane.next_interrupt
    expect(result["id"]).to eq(l0_id)
  end

  it "next_interrupt nil when no l0" do
    @task.create(source: "telegram", chat_id: "1", lane: Skein::Lane::L1_INTERACTIVE)
    expect(@lane.next_interrupt).to be_nil
  end

  it "next_interactive returns l1 only" do
    l1_id = @task.create(source: "telegram", chat_id: "1", lane: Skein::Lane::L1_INTERACTIVE)
    @task.create(source: "heartbeat", lane: Skein::Lane::L0_INTERRUPT)
    result = @lane.next_interactive
    expect(result["id"]).to eq(l1_id)
  end

  it "next_interactive nil when no l1" do
    @task.create(source: "heartbeat", lane: Skein::Lane::L0_INTERRUPT)
    expect(@lane.next_interactive).to be_nil
  end

  it "interrupt_pending? true when l0 exists" do
    @task.create(source: "heartbeat", lane: Skein::Lane::L0_INTERRUPT)
    expect(@lane.interrupt_pending?).to be_truthy
  end

  it "interrupt_pending? false when only l1" do
    @task.create(source: "telegram", chat_id: "1", lane: Skein::Lane::L1_INTERACTIVE)
    expect(@lane.interrupt_pending?).to be_falsey
  end

  it "interrupt_pending? false when empty" do
    expect(@lane.interrupt_pending?).to be_falsey
  end
end
