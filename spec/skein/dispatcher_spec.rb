require "spec_helper"
require "skein/event_store"
require "skein/task"
require "skein/lane"
require "skein/dispatcher"

RSpec.describe Skein::Dispatcher::Sequential do
  describe "with stub agent" do
    before do
      @db = Skein::DB.new(":memory:", vec: false)
      @events = Skein::EventStore.new(@db)
      @tasks = Skein::Task.new(db: @db, event_store: @events)
      @lane = Skein::Lane.new(task: @tasks)
      @processed = []
      @agent = stub_agent(@processed)
      @dispatcher = Skein::Dispatcher::Sequential.new(lane: @lane, tasks: @tasks, agent: @agent)
    end

    it "tick returns false when no tasks" do
      expect(@dispatcher.tick).to be_falsey
    end

    it "tick processes task" do
      id = @tasks.create(source: "test", chat_id: "1", input_text: "hello")
      expect(@dispatcher.tick).to be_truthy
      expect(@processed.map { |t| t["id"] }).to eq([id])
    end

    it "tick transitions to running" do
      id = @tasks.create(source: "test", chat_id: "1", input_text: "hello")
      @dispatcher.tick
      task = @tasks.find(id)
      expect(task["state"]).to eq("running")
    end

    it "l0 preempts l1" do
      @tasks.create(source: "test", chat_id: "1", input_text: "user msg", lane: Skein::Lane::L1_INTERACTIVE)
      l0_id = @tasks.create(source: "heartbeat", lane: Skein::Lane::L0_INTERRUPT)
      @dispatcher.tick
      expect(@processed.first["id"]).to eq(l0_id)
    end

    it "processes all in priority order" do
      l1_id = @tasks.create(source: "test", chat_id: "1", input_text: "user msg", lane: Skein::Lane::L1_INTERACTIVE)
      l0_id = @tasks.create(source: "heartbeat", lane: Skein::Lane::L0_INTERRUPT)
      @dispatcher.tick
      @dispatcher.tick
      expect(@processed.map { |t| t["id"] }).to eq([l0_id, l1_id])
    end

    it "busy? always false" do
      expect(@dispatcher.busy?).to be_falsey
      expect(@dispatcher.busy?(Skein::Lane::L0_INTERRUPT)).to be_falsey
      expect(@dispatcher.busy?(Skein::Lane::L1_INTERACTIVE)).to be_falsey
    end

    it "shutdown is noop" do
      expect { @dispatcher.shutdown }.not_to raise_error
    end
  end

  describe "with completing agent" do
    before do
      @db = Skein::DB.new(":memory:", vec: false)
      @events = Skein::EventStore.new(@db)
      @tasks = Skein::Task.new(db: @db, event_store: @events)
      @lane = Skein::Lane.new(task: @tasks)
      @processed = []
      @agent = completing_agent(@processed, @tasks)
      @dispatcher = Skein::Dispatcher::Sequential.new(lane: @lane, tasks: @tasks, agent: @agent)
    end

    it "multiple ticks process sequentially" do
      id1 = @tasks.create(source: "test", chat_id: "1", input_text: "first")
      id2 = @tasks.create(source: "test", chat_id: "1", input_text: "second")
      @dispatcher.tick
      @dispatcher.tick
      expect(@processed.map { |t| t["id"] }).to eq([id1, id2])
    end

    it "idle after all processed" do
      @tasks.create(source: "test", chat_id: "1", input_text: "only")
      expect(@dispatcher.tick).to be_truthy
      expect(@dispatcher.tick).to be_falsey
    end
  end

  def stub_agent(processed_log)
    agent = Object.new
    agent.define_singleton_method(:process_task) do |task|
      processed_log << task
    end
    agent
  end

  def completing_agent(processed_log, tasks)
    agent = Object.new
    agent.define_singleton_method(:process_task) do |task|
      processed_log << task
      tasks.transition!(task["id"], "completed", result_text: "done")
    end
    agent
  end
end
