require "spec_helper"
require "skein/config"
require "skein/event_store"
require "skein/task"
require "skein/timer"
require "skein/memory"
require "skein/lesson"
require "skein/sdk_client"
require "skein/tool_executor"
require "skein/agent"
require "json"

# Mock SDK client that returns canned results without spawning Claude CLI
class MockSdkClient
  attr_reader :tasks_sent
  attr_accessor :next_result, :next_extract_result, :next_decompose_result, :current_task_id

  def initialize
    @tasks_sent = []
    @on_stream = nil
    @next_result = {
      "type" => "result",
      "text" => "Hello from the SDK!",
      "session_id" => "sess-test-123",
      "structured_output" => nil,
    }
    @started = false
  end

  def start
    @started = true
  end

  def shutdown
    @started = false
  end

  def alive?
    @started
  end

  def on_stream(&block)
    @on_stream = block
  end

  def send_task(input, chat_id:, session_id: nil, memories: "", lessons: "", timeout: 300)
    @tasks_sent << {
      input: input, chat_id: chat_id, session_id: session_id,
      memories: memories, lessons: lessons, timeout: timeout
    }
    @next_result
  end

  def send_extract(conversation_text, extract_type: "lessons", timeout: 60)
    @extractions_sent ||= []
    @extractions_sent << { text: conversation_text, type: extract_type, timeout: timeout }
    if @next_extract_result
      @next_extract_result
    else
      case extract_type
      when "lessons"  then { "lessons" => [] }
      when "memories" then { "memories" => [] }
      when "summary"  then { "summary" => "Mock summary of conversation." }
      when "consolidate" then { "memories" => [] }
      else { "lessons" => [] }
      end
    end
  end

  def extractions_sent
    @extractions_sent ||= []
  end

  def send_decompose(input_text, timeout: 30)
    @decompose_requests ||= []
    @decompose_requests << { input: input_text, timeout: timeout }
    @decompose_calls ||= []
    @decompose_calls << input_text
    @next_decompose_result || { "decompose" => false, "subtasks" => [] }
  end

  def decompose_calls
    @decompose_calls ||= []
  end

  def decompose_requests
    @decompose_requests ||= []
  end

  def register_tools(tool_definitions)
    # no-op
  end

  # Test helper — simulate stream callback
  def simulate_stream(task_id, text)
    @on_stream&.call(task_id, text)
  end
end

# Mock channel that records calls
class MockChannel
  attr_reader :replies, :approval_requests

  def initialize(approval_decision: "allow")
    @replies = []
    @approval_requests = []
    @approval_decision = approval_decision
  end

  def send_reply(chat_id, text)
    @replies << { chat_id: chat_id, text: text }
  end

  def request_approval(chat_id, tool_name, tool_input)
    @approval_requests << { chat_id: chat_id, tool_name: tool_name, tool_input: tool_input }
    @approval_decision
  end
end

RSpec.describe Skein::Agent do
  before do
    @db = Skein::DB.new(":memory:", vec: false)
    @events = Skein::EventStore.new(@db)
    @tasks = Skein::Task.new(db: @db, event_store: @events)
    @timers = Skein::Timer.new(db: @db, event_store: @events)
    @memory = Skein::Memory.new(db: @db, event_store: @events)
    @lessons = Skein::Lesson.new(db: @db, event_store: @events)

    @config = Skein::Config.new(
      system_prompt_path: File.expand_path("../../docs/SYSTEM_PROMPT.md", __dir__),
      heartbeat_path: File.expand_path("../../docs/HEARTBEAT.md", __dir__)
    )
  end

  def build_agent(sdk_client: MockSdkClient.new, channel: MockChannel.new)
    tool_executor = Skein::ToolExecutor.new(memory: @memory, timers: @timers)
    Skein::Agent.new(
      config: @config, db: @db, events: @events, tasks: @tasks,
      timers: @timers, memory: @memory, lessons: @lessons,
      sdk_client: sdk_client, tool_executor: tool_executor,
      channel: channel, logger: ->(_msg) {}
    )
  end

  def create_task(input: "hello", chat_id: "test_chat")
    task_id = @tasks.create(source: "test", chat_id: chat_id, input_text: input)
    @tasks.transition!(task_id, "running")
    @tasks.find(task_id)
  end

  # --- Text response flow ---

  describe "text response flow" do
    it "sends task to SDK client" do
      sdk_client = MockSdkClient.new
      channel = MockChannel.new
      agent = build_agent(sdk_client: sdk_client, channel: channel)
      task = create_task(input: "hello world")

      agent.process_task(task)

      expect(sdk_client.tasks_sent.size).to eq(1)
      expect(sdk_client.tasks_sent[0][:input]).to eq("hello world")
      expect(sdk_client.tasks_sent[0][:chat_id]).to eq("test_chat")
      expect(sdk_client.tasks_sent[0][:timeout]).to eq(@config.task_timeout)
    end

    it "completes with result" do
      sdk_client = MockSdkClient.new
      sdk_client.next_result = {
        "type" => "result", "text" => "Hello there!",
        "session_id" => "s1", "structured_output" => nil
      }
      channel = MockChannel.new
      agent = build_agent(sdk_client: sdk_client, channel: channel)
      task = create_task

      agent.process_task(task)

      updated = @tasks.find(task["id"])
      expect(updated["state"]).to eq("completed")
      expect(updated["result_text"]).to eq("Hello there!")
    end

    it "sends reply to channel" do
      sdk_client = MockSdkClient.new
      sdk_client.next_result = {
        "type" => "result", "text" => "Hi!",
        "session_id" => "s1", "structured_output" => nil
      }
      channel = MockChannel.new
      agent = build_agent(sdk_client: sdk_client, channel: channel)
      task = create_task

      agent.process_task(task)

      expect(channel.replies.size).to eq(1)
      expect(channel.replies[0][:text]).to eq("Hi!")
      expect(channel.replies[0][:chat_id]).to eq("test_chat")
    end

    it "stores assistant turn" do
      sdk_client = MockSdkClient.new
      sdk_client.next_result = {
        "type" => "result", "text" => "Hi",
        "session_id" => "s1", "structured_output" => nil
      }
      channel = MockChannel.new
      agent = build_agent(sdk_client: sdk_client, channel: channel)
      task = create_task

      agent.process_task(task)

      turns = agent.recent_turns(chat_id: "test_chat")
      user_turns = turns.select { |t| t["role"] == "user" }
      assistant_turns = turns.select { |t| t["role"] == "assistant" }
      expect(user_turns.size).to eq(1)
      expect(assistant_turns.size).to eq(1)
      expect(assistant_turns.first["content"]).to eq("Hi")
    end

    it "forwards session_id" do
      sdk_client = MockSdkClient.new
      sdk_client.next_result = {
        "type" => "result", "text" => "First reply",
        "session_id" => "sess-abc", "structured_output" => nil
      }
      channel = MockChannel.new
      agent = build_agent(sdk_client: sdk_client, channel: channel)

      # First task — no session
      task1 = create_task(input: "first")
      agent.process_task(task1)
      expect(sdk_client.tasks_sent[0][:session_id]).to be_nil

      # Second task — should forward the session from first
      sdk_client.next_result = {
        "type" => "result", "text" => "Second reply",
        "session_id" => "sess-def", "structured_output" => nil
      }
      task2 = create_task(input: "second")
      agent.process_task(task2)
      expect(sdk_client.tasks_sent[1][:session_id]).to eq("sess-abc")
    end

    it "includes memories and lessons" do
      @memory.store(content: "User likes Ruby", category: "preference")
      @lessons.store(content: "Be concise", category: "tone")

      sdk_client = MockSdkClient.new
      agent = build_agent(sdk_client: sdk_client)
      task = create_task

      agent.process_task(task)

      expect(sdk_client.tasks_sent[0][:memories]).to match(/Ruby/)
      expect(sdk_client.tasks_sent[0][:lessons]).to match(/concise/)
    end
  end

  describe "session and context management" do
    it "clears stored session for a chat" do
      sdk_client = MockSdkClient.new
      agent = build_agent(sdk_client: sdk_client)

      @db.execute(
        "INSERT INTO sessions (chat_id, session_id) VALUES (?, ?)",
        ["test_chat", "sess-123"]
      )

      existing = @db.get_first_row("SELECT session_id FROM sessions WHERE chat_id = ?", ["test_chat"])
      expect(existing["session_id"]).to eq("sess-123")

      agent.clear_session!("test_chat")

      cleared = @db.get_first_row("SELECT session_id FROM sessions WHERE chat_id = ?", ["test_chat"])
      expect(cleared).to be_nil
      events = @events.recent(type: "session_cleared", limit: 1)
      expect(events.size).to eq(1)
      expect(events[0]["payload"]["chat_id"]).to eq("test_chat")
    end

    it "clears turns and summary for one chat only" do
      sdk_client = MockSdkClient.new
      agent = build_agent(sdk_client: sdk_client)

      agent.store_turn(chat_id: "test_chat", role: "user", content: "hello")
      agent.store_turn(chat_id: "other_chat", role: "user", content: "hi")
      @db.execute(
        "INSERT INTO conversation_summaries (chat_id, summary, turns_summarized) VALUES (?, ?, ?)",
        ["test_chat", "summary text", 3]
      )
      @db.execute(
        "INSERT INTO conversation_summaries (chat_id, summary, turns_summarized) VALUES (?, ?, ?)",
        ["other_chat", "other summary", 1]
      )

      agent.clear_context!("test_chat")

      test_chat_turns = @db.get_first_row(
        "SELECT COUNT(*) AS cnt FROM conversation_turns WHERE chat_id = ?",
        ["test_chat"]
      )
      other_chat_turns = @db.get_first_row(
        "SELECT COUNT(*) AS cnt FROM conversation_turns WHERE chat_id = ?",
        ["other_chat"]
      )
      expect(test_chat_turns["cnt"]).to eq(0)
      expect(other_chat_turns["cnt"]).to eq(1)

      test_summary = @db.get_first_row(
        "SELECT * FROM conversation_summaries WHERE chat_id = ?",
        ["test_chat"]
      )
      other_summary = @db.get_first_row(
        "SELECT * FROM conversation_summaries WHERE chat_id = ?",
        ["other_chat"]
      )
      expect(test_summary).to be_nil
      expect(other_summary).not_to be_nil

      events = @events.recent(type: "conversation_cleared", limit: 1)
      expect(events.size).to eq(1)
      expect(events[0]["payload"]["chat_id"]).to eq("test_chat")
    end
  end

  # --- Error handling ---

  describe "error handling" do
    it "handles SDK error" do
      sdk_client = MockSdkClient.new
      def sdk_client.send_task(*, **)
        raise Skein::SdkClient::SdkError, "SDK error: connection lost"
      end
      channel = MockChannel.new
      agent = build_agent(sdk_client: sdk_client, channel: channel)
      task = create_task

      agent.process_task(task)

      updated = @tasks.find(task["id"])
      expect(updated["state"]).to eq("failed")
      expect(updated["error_message"]).to match(/SDK error: connection lost/)
    end

    it "clears stale session on process failure" do
      @db.execute(
        "INSERT INTO sessions (chat_id, session_id) VALUES (?, ?)",
        ["test_chat", "stale-session"]
      )

      sdk_client = MockSdkClient.new
      def sdk_client.send_task(*, **)
        raise Skein::SdkClient::SdkError, "Claude process failed: Command failed with exit code 1"
      end

      agent = build_agent(sdk_client: sdk_client, channel: MockChannel.new)
      task = create_task(chat_id: "test_chat")

      agent.process_task(task)

      row = @db.get_first_row("SELECT session_id FROM sessions WHERE chat_id = ?", ["test_chat"])
      expect(row).to be_nil
    end
  end

  # --- Store/recent turns ---

  describe "store and recent turns" do
    it "stores and retrieves turns" do
      agent = build_agent
      agent.store_turn(chat_id: "test", role: "user", content: "hello")
      agent.store_turn(chat_id: "test", role: "assistant", content: "hi")
      agent.store_turn(chat_id: "other", role: "user", content: "different chat")

      turns = agent.recent_turns(chat_id: "test")
      expect(turns.size).to eq(2)
      expect(turns[0]["role"]).to eq("user")
      expect(turns[1]["role"]).to eq("assistant")
    end

    it "returns empty for nil chat_id" do
      agent = build_agent
      expect(agent.recent_turns(chat_id: nil)).to eq([])
    end
  end

  # --- Recovery ---

  describe "recovery" do
    it "recovers stale tasks" do
      agent = build_agent

      task_id = @tasks.create(source: "test", input_text: "stale")
      @tasks.transition!(task_id, "running")

      @db.execute(
        "UPDATE tasks SET updated_at = ? WHERE id = ?",
        [(Time.now.utc - 600).strftime("%Y-%m-%dT%H:%M:%S.%L"), task_id]
      )

      agent.recover_stale_tasks!

      updated = @tasks.find(task_id)
      expect(updated["state"]).to eq("failed")
      expect(updated["error_message"]).to match(/Stale/)
    end
  end

  # --- Task decomposition ---

  describe "task decomposition" do
    it "does not decompose short input" do
      sdk_client = MockSdkClient.new
      agent = build_agent(sdk_client: sdk_client)
      task = create_task(input: "hello")  # < 80 chars

      agent.process_task(task)

      expect(sdk_client.decompose_calls.size).to eq(0)
    end

    it "checks long input for decomposition" do
      sdk_client = MockSdkClient.new
      agent = build_agent(sdk_client: sdk_client)
      long_input = "Please set up a new Rails project with authentication, add a PostgreSQL database, and deploy it to production with SSL"
      task = create_task(input: long_input)

      agent.process_task(task)

      expect(sdk_client.decompose_calls.size).to eq(1)
      expect(sdk_client.decompose_calls[0]).to eq(long_input)
      expect(sdk_client.decompose_requests[0][:timeout]).to eq(@config.decompose_timeout)
    end

    it "decomposes task into subtasks" do
      sdk_client = MockSdkClient.new
      sdk_client.next_decompose_result = {
        "decompose" => true,
        "subtasks" => [
          { "title" => "Set up Rails project", "input" => "Create a new Rails 8 project with basic structure" },
          { "title" => "Add authentication", "input" => "Add authentication using Rails built-in auth" },
          { "title" => "Deploy to production", "input" => "Deploy the project with SSL certificates" },
        ]
      }
      channel = MockChannel.new
      agent = build_agent(sdk_client: sdk_client, channel: channel)
      long_input = "Please set up a new Rails project with authentication and deploy it to production with SSL"
      task_id = @tasks.create(source: "test", chat_id: "test_chat", input_text: long_input)
      @tasks.transition!(task_id, "running")
      task = @tasks.find(task_id)

      agent.process_task(task)

      # Parent should be in waiting_for_input
      parent = @tasks.find(task_id)
      expect(parent["state"]).to eq("waiting_for_input")

      # Should have created 3 subtasks
      subtasks = @tasks.subtasks(task_id)
      expect(subtasks.size).to eq(3)
      expect(subtasks[0]["input_text"]).to eq("Create a new Rails 8 project with basic structure")
      expect(subtasks[1]["input_text"]).to eq("Add authentication using Rails built-in auth")

      # Channel should have been notified
      expect(channel.replies.size).to eq(1)
      expect(channel.replies[0][:text]).to match(/3 steps/)
    end

    it "triggers parent completion when all subtasks complete" do
      sdk_client = MockSdkClient.new
      channel = MockChannel.new
      agent = build_agent(sdk_client: sdk_client, channel: channel)

      # Create parent task in waiting_for_input state
      parent_id = @tasks.create(source: "test", chat_id: "test_chat", input_text: "complex task")
      @tasks.transition!(parent_id, "running")
      @tasks.transition!(parent_id, "waiting_for_input")

      # Create 2 subtasks
      sub1_id = @tasks.create(
        source: "test", chat_id: "test_chat", input_text: "step 1",
        parent_task_id: parent_id, subtask_index: 0
      )
      sub2_id = @tasks.create(
        source: "test", chat_id: "test_chat", input_text: "step 2",
        parent_task_id: parent_id, subtask_index: 1
      )

      # Process first subtask
      @tasks.transition!(sub1_id, "running")
      sub1 = @tasks.find(sub1_id)
      sdk_client.next_result = {
        "type" => "result", "text" => "Step 1 done",
        "session_id" => "s1", "structured_output" => nil
      }
      agent.process_task(sub1)

      # Parent should still be waiting (sub2 not done yet)
      expect(@tasks.find(parent_id)["state"]).to eq("waiting_for_input")

      # Process second subtask
      @tasks.transition!(sub2_id, "running")
      sub2 = @tasks.find(sub2_id)
      sdk_client.next_result = {
        "type" => "result", "text" => "Step 2 done",
        "session_id" => "s2", "structured_output" => nil
      }
      agent.process_task(sub2)

      # Parent should now be completed with aggregated results
      parent = @tasks.find(parent_id)
      expect(parent["state"]).to eq("completed")
      expect(parent["result_text"]).to match(/Step 1 done/)
      expect(parent["result_text"]).to match(/Step 2 done/)

      # Channel should have been notified
      completion_replies = channel.replies.select { |r| r[:text].include?("All steps complete") }
      expect(completion_replies.size).to eq(1)
    end

    it "does not decompose subtasks" do
      sdk_client = MockSdkClient.new
      agent = build_agent(sdk_client: sdk_client)

      # Create a parent + subtask
      parent_id = @tasks.create(source: "test", chat_id: "test_chat", input_text: "complex task")
      @tasks.transition!(parent_id, "running")
      @tasks.transition!(parent_id, "waiting_for_input")

      sub_id = @tasks.create(
        source: "test", chat_id: "test_chat",
        input_text: "A" * 100,  # Long enough to trigger decomposition check
        parent_task_id: parent_id, subtask_index: 0
      )
      @tasks.transition!(sub_id, "running")
      subtask = @tasks.find(sub_id)

      agent.process_task(subtask)

      expect(sdk_client.decompose_calls.size).to eq(0)
    end

    it "falls back to direct processing on decomposition failure" do
      sdk_client = MockSdkClient.new
      sdk_client.define_singleton_method(:send_decompose) do |*args, **kwargs|
        raise "LLM timeout"
      end
      channel = MockChannel.new
      agent = build_agent(sdk_client: sdk_client, channel: channel)
      long_input = "A" * 100
      task = create_task(input: long_input)

      agent.process_task(task)

      updated = @tasks.find(task["id"])
      expect(updated["state"]).to eq("completed")
    end
  end

  # --- Learning extraction ---

  describe "learning extraction" do
    it "runs after task completion" do
      sdk_client = MockSdkClient.new
      channel = MockChannel.new
      agent = build_agent(sdk_client: sdk_client, channel: channel)

      task = create_task(input: "What's Ruby 4.0 like?")

      agent.process_task(task)

      # Should have sent extraction requests (lessons + memories)
      expect(sdk_client.extractions_sent.size).to eq(2)
      expect(sdk_client.extractions_sent[0][:type]).to eq("lessons")
      expect(sdk_client.extractions_sent[1][:type]).to eq("memories")
      expect(sdk_client.extractions_sent[0][:timeout]).to eq(@config.extract_timeout)
      expect(sdk_client.extractions_sent[1][:timeout]).to eq(@config.extract_timeout)
    end

    it "stores extracted lessons" do
      sdk_client = MockSdkClient.new
      sdk_client.next_extract_result = {
        "lessons" => [
          { "content" => "Be more concise", "category" => "tone" },
          { "content" => "Explain tool choices", "category" => "tool_use" },
        ]
      }
      channel = MockChannel.new
      agent = build_agent(sdk_client: sdk_client, channel: channel)

      task = create_task(input: "hello")
      agent.process_task(task)

      expect(@lessons.count).to eq(2)
      top = @lessons.top(limit: 2)
      contents = top.map { |l| l["content"] }
      expect(contents).to include("Be more concise")
      expect(contents).to include("Explain tool choices")
    end

    it "stores extracted memories" do
      sdk_client = MockSdkClient.new
      # First call returns memories, second returns empty lessons
      extract_call = 0
      sdk_client.define_singleton_method(:send_extract) do |text, extract_type:, timeout: 60|
        extract_call += 1
        if extract_type == "memories"
          { "memories" => [{ "content" => "User uses Ruby 4.0", "category" => "fact" }] }
        else
          { "lessons" => [] }
        end
      end
      channel = MockChannel.new
      agent = build_agent(sdk_client: sdk_client, channel: channel)

      task = create_task(input: "I use Ruby 4.0")
      agent.process_task(task)

      expect(@memory.count).to eq(1)
    end

    it "skips extraction when no chat_id" do
      sdk_client = MockSdkClient.new
      channel = MockChannel.new
      agent = build_agent(sdk_client: sdk_client, channel: channel)

      # Task with no chat_id (e.g. system heartbeat) — no turns stored, no extraction
      task_id = @tasks.create(source: "heartbeat", input_text: "check status")
      @tasks.transition!(task_id, "running")
      task = @tasks.find(task_id)
      agent.process_task(task)

      expect(sdk_client.extractions_sent.size).to eq(0)
    end

    it "does not fail task when extraction errors" do
      sdk_client = MockSdkClient.new
      sdk_client.define_singleton_method(:send_extract) do |*args, **kwargs|
        raise "Extraction crashed!"
      end
      channel = MockChannel.new
      agent = build_agent(sdk_client: sdk_client, channel: channel)

      task = create_task(input: "hello")
      agent.process_task(task)

      updated = @tasks.find(task["id"])
      expect(updated["state"]).to eq("completed")
    end
  end

  # --- Conversation summarization ---

  describe "conversation summarization" do
    it "skips summarization below threshold" do
      sdk_client = MockSdkClient.new
      agent = build_agent(sdk_client: sdk_client)

      # Store fewer turns than threshold (40)
      10.times do |i|
        agent.store_turn(chat_id: "test_chat", role: "user", content: "msg #{i}")
        agent.store_turn(chat_id: "test_chat", role: "assistant", content: "reply #{i}")
      end

      task = create_task(input: "hello")
      agent.process_task(task)

      # Should not have sent a summary extraction
      summary_extractions = sdk_client.extractions_sent.select { |e| e[:type] == "summary" }
      expect(summary_extractions.size).to eq(0)
    end

    it "runs summarization above threshold" do
      @config = Skein::Config.new(
        system_prompt_path: File.expand_path("../../docs/SYSTEM_PROMPT.md", __dir__),
        heartbeat_path: File.expand_path("../../docs/HEARTBEAT.md", __dir__),
        max_context_turns: 5,
        summary_threshold: 10
      )

      sdk_client = MockSdkClient.new
      agent = build_agent(sdk_client: sdk_client)

      # Store enough turns to exceed threshold
      8.times do |i|
        agent.store_turn(chat_id: "test_chat", role: "user", content: "msg #{i}")
        agent.store_turn(chat_id: "test_chat", role: "assistant", content: "reply #{i}")
      end
      # 16 turns total > threshold of 10

      task = create_task(input: "trigger summarization")
      agent.process_task(task)

      # Should have sent a summary extraction
      summary_extractions = sdk_client.extractions_sent.select { |e| e[:type] == "summary" }
      expect(summary_extractions.size).to eq(1)
      expect(summary_extractions[0][:timeout]).to eq(@config.summary_timeout)

      # Old turns should be deleted, recent ones kept
      remaining = agent.recent_turns(chat_id: "test_chat")
      expect(remaining.size).to be <= 5 + 2  # keep=5 + the new user+assistant turns from process_task
    end

    it "stores summary in DB" do
      @config = Skein::Config.new(
        system_prompt_path: File.expand_path("../../docs/SYSTEM_PROMPT.md", __dir__),
        heartbeat_path: File.expand_path("../../docs/HEARTBEAT.md", __dir__),
        max_context_turns: 5, summary_threshold: 10
      )

      sdk_client = MockSdkClient.new
      agent = build_agent(sdk_client: sdk_client)

      12.times do |i|
        agent.store_turn(chat_id: "test_chat", role: "user", content: "msg #{i}")
      end

      task = create_task(input: "hello")
      agent.process_task(task)

      # Summary should be persisted
      row = @db.get_first_row(
        "SELECT * FROM conversation_summaries WHERE chat_id = ?", ["test_chat"]
      )
      expect(row).not_to be_nil
      expect(row["summary"]).to eq("Mock summary of conversation.")
      expect(row["turns_summarized"].to_i).to be > 0
    end

    it "includes summary when no session exists" do
      sdk_client = MockSdkClient.new
      agent = build_agent(sdk_client: sdk_client)

      # Manually save a summary
      @db.execute(
        "INSERT INTO conversation_summaries (chat_id, summary, turns_summarized) VALUES (?, ?, ?)",
        ["test_chat", "Previously discussed Ruby 4.0 features.", 20]
      )

      task = create_task(input: "continue our discussion")
      agent.process_task(task)

      # The memories field should include the summary
      expect(sdk_client.tasks_sent[0][:memories]).to match(/Previously discussed Ruby 4.0/)
    end

    it "does not include summary when session exists" do
      sdk_client = MockSdkClient.new
      sdk_client.next_result = {
        "type" => "result", "text" => "First reply",
        "session_id" => "sess-existing", "structured_output" => nil
      }
      agent = build_agent(sdk_client: sdk_client)

      # Save a session so the next task has one
      @db.execute(
        "INSERT INTO sessions (chat_id, session_id) VALUES (?, ?)",
        ["test_chat", "sess-existing"]
      )
      # Also save a summary
      @db.execute(
        "INSERT INTO conversation_summaries (chat_id, summary, turns_summarized) VALUES (?, ?, ?)",
        ["test_chat", "Old summary.", 20]
      )

      task = create_task(input: "hello again")
      agent.process_task(task)

      # Summary should NOT be in memories when session exists
      expect(sdk_client.tasks_sent[0][:memories]).not_to match(/Old summary/)
    end

    it "does not fail task when summarization errors" do
      @config = Skein::Config.new(
        system_prompt_path: File.expand_path("../../docs/SYSTEM_PROMPT.md", __dir__),
        heartbeat_path: File.expand_path("../../docs/HEARTBEAT.md", __dir__),
        max_context_turns: 5, summary_threshold: 10
      )

      sdk_client = MockSdkClient.new
      # Make summary extraction fail
      original_send = sdk_client.method(:send_extract)
      sdk_client.define_singleton_method(:send_extract) do |text, extract_type:, timeout: 60|
        raise "Summarization crashed!" if extract_type == "summary"
        original_send.call(text, extract_type: extract_type, timeout: timeout)
      end
      channel = MockChannel.new
      agent = build_agent(sdk_client: sdk_client, channel: channel)

      12.times { |i| agent.store_turn(chat_id: "test_chat", role: "user", content: "msg #{i}") }

      task = create_task(input: "hello")
      agent.process_task(task)

      # Task should still complete
      updated = @tasks.find(task["id"])
      expect(updated["state"]).to eq("completed")
    end
  end

  describe "maintenance config" do
    it "uses configured event retention days for pruning" do
      @config = Skein::Config.new(
        system_prompt_path: File.expand_path("../../docs/SYSTEM_PROMPT.md", __dir__),
        heartbeat_path: File.expand_path("../../docs/HEARTBEAT.md", __dir__),
        event_retention_days: 7
      )

      sdk_client = MockSdkClient.new
      agent = build_agent(sdk_client: sdk_client)

      allow(@lessons).to receive(:prune!).and_return(0)
      expect(@events).to receive(:prune!).with(days: 7).and_return(0)

      agent.maintenance!
    end

    it "uses configured embedding backfill batch size" do
      @config = Skein::Config.new(
        system_prompt_path: File.expand_path("../../docs/SYSTEM_PROMPT.md", __dir__),
        heartbeat_path: File.expand_path("../../docs/HEARTBEAT.md", __dir__),
        embedding_backfill_batch_size: 77
      )

      sdk_client = MockSdkClient.new
      agent = build_agent(sdk_client: sdk_client)

      allow(@lessons).to receive(:prune!).and_return(0)
      allow(@events).to receive(:prune!).and_return(0)
      allow(agent).to receive(:consolidate_memories!)
      expect(@memory).to receive(:backfill_embeddings).with(batch_size: 77).and_return(0)

      agent.maintenance!
    end
  end

  # --- Memory consolidation ---

  describe "memory consolidation" do
    it "skips consolidation below threshold" do
      sdk_client = MockSdkClient.new
      agent = build_agent(sdk_client: sdk_client)
      agent.start_sdk

      # Store fewer memories than threshold (100)
      5.times { |i| @memory.store(content: "Fact #{i}", category: "fact") }

      agent.maintenance!

      # Should not have sent a consolidation extraction
      consolidate_extractions = sdk_client.extractions_sent.select { |e| e[:type] == "consolidate" }
      expect(consolidate_extractions.size).to eq(0)
    end

    it "runs consolidation above threshold" do
      @config = Skein::Config.new(
        system_prompt_path: File.expand_path("../../docs/SYSTEM_PROMPT.md", __dir__),
        heartbeat_path: File.expand_path("../../docs/HEARTBEAT.md", __dir__),
        memory_consolidation_threshold: 10
      )

      sdk_client = MockSdkClient.new
      # Return a consolidated list (fewer than original)
      sdk_client.define_singleton_method(:send_extract) do |text, extract_type:, timeout: 60|
        @extractions_sent ||= []
        @extractions_sent << { text: text, type: extract_type, timeout: timeout }
        if extract_type == "consolidate"
          { "memories" => [
            { "content" => "User likes Ruby and Rails", "category" => "preference" },
            { "content" => "User is named Andrew", "category" => "fact" },
            { "content" => "Works on Skein project", "category" => "project" },
            { "content" => "Uses Telegram for communication", "category" => "fact" },
            { "content" => "Prefers concise responses", "category" => "preference" },
          ] }
        else
          { "lessons" => [] }
        end
      end

      agent = build_agent(sdk_client: sdk_client)
      agent.start_sdk

      # Store more memories than threshold
      15.times { |i| @memory.store(content: "Fact #{i}", category: "fact") }
      expect(@memory.count).to eq(15)

      agent.maintenance!

      # Should have consolidated
      consolidate_extractions = sdk_client.extractions_sent.select { |e| e[:type] == "consolidate" }
      expect(consolidate_extractions.size).to eq(1)
      expect(consolidate_extractions[0][:timeout]).to eq(@config.consolidate_timeout)

      # Memory count should be reduced
      expect(@memory.count).to eq(5)
    end

    it "aborts consolidation when result too small" do
      @config = Skein::Config.new(
        system_prompt_path: File.expand_path("../../docs/SYSTEM_PROMPT.md", __dir__),
        heartbeat_path: File.expand_path("../../docs/HEARTBEAT.md", __dir__),
        memory_consolidation_threshold: 10
      )

      sdk_client = MockSdkClient.new
      # Return suspiciously few memories (below configured safety threshold)
      sdk_client.define_singleton_method(:send_extract) do |text, extract_type:, timeout: 60|
        @extractions_sent ||= []
        @extractions_sent << { text: text, type: extract_type, timeout: timeout }
        if extract_type == "consolidate"
          { "memories" => [{ "content" => "Only one", "category" => "fact" }] }
        else
          { "lessons" => [] }
        end
      end

      agent = build_agent(sdk_client: sdk_client)
      agent.start_sdk

      15.times { |i| @memory.store(content: "Fact #{i}", category: "fact") }

      agent.maintenance!

      # Should have aborted — memories unchanged
      expect(@memory.count).to eq(15)
    end

    it "does not crash on consolidation error" do
      @config = Skein::Config.new(
        system_prompt_path: File.expand_path("../../docs/SYSTEM_PROMPT.md", __dir__),
        heartbeat_path: File.expand_path("../../docs/HEARTBEAT.md", __dir__),
        memory_consolidation_threshold: 5
      )

      sdk_client = MockSdkClient.new
      sdk_client.define_singleton_method(:send_extract) do |text, extract_type:, timeout: 60|
        raise "Consolidation exploded!" if extract_type == "consolidate"
        { "lessons" => [] }
      end

      agent = build_agent(sdk_client: sdk_client)
      agent.start_sdk

      10.times { |i| @memory.store(content: "Fact #{i}", category: "fact") }

      # Should not raise
      expect { agent.maintenance! }.not_to raise_error

      # Memories should be untouched
      expect(@memory.count).to eq(10)
    end
  end

  # --- SDK lifecycle ---

  describe "SDK lifecycle" do
    it "starts and stops SDK" do
      sdk_client = MockSdkClient.new
      agent = build_agent(sdk_client: sdk_client)

      expect(sdk_client.alive?).to be false
      agent.start_sdk
      expect(sdk_client.alive?).to be true
      agent.stop_sdk
      expect(sdk_client.alive?).to be false
    end
  end
end
