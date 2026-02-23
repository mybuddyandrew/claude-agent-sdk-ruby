require "spec_helper"
require "skein/config"
require "skein/db"
require "skein/event_store"
require "skein/memory"
require "skein/timer"
require "skein/tool_executor"
require "skein/sdk_client"
require "skein/tools/remember"
require "skein/tools/recall"
require "skein/tools/send_telegram"
require "skein/tools/create_reminder"
require "skein/tools/write_note"

RSpec.describe Skein::SdkClient do
  let(:db) { Skein::DB.new(":memory:") }
  let(:events) { Skein::EventStore.new(db) }
  let(:memory) { Skein::Memory.new(db: db, event_store: events) }
  let(:timers) { Skein::Timer.new(db: db, event_store: events) }
  let(:config) do
    Skein::Config.new(
      telegram_token: "fake",
      system_prompt_path: "/nonexistent/prompt.md",
      model: "sonnet",
      auto_approve_rules: []
    )
  end
  let(:channel) { double("channel") }
  let(:logs) { [] }
  let(:logger) { ->(msg) { logs << msg } }
  let(:tool_executor) { Skein::ToolExecutor.new(memory: memory, timers: timers, config: config) }
  let(:client) do
    Skein::SdkClient.new(
      config: config, tool_executor: tool_executor,
      channel: channel, logger: logger
    )
  end

  describe "lifecycle" do
    it "starts in stopped state" do
      expect(client.running).to be false
      expect(client.alive?).to be false
    end

    it "start sets running to true" do
      client.start
      expect(client.running).to be true
      expect(client.alive?).to be true
    end

    it "shutdown sets running to false" do
      client.start
      client.shutdown
      expect(client.running).to be false
      expect(client.alive?).to be false
    end

    it "start logs the CLI path" do
      client.start
      expect(logs.last).to match(/SDK client started/)
      expect(logs.last).to match(/claude/)
    end

    it "shutdown logs" do
      client.shutdown
      expect(logs.last).to match(/SDK client stopped/)
    end
  end

  describe "on_stream callback" do
    it "accepts a block" do
      called = false
      client.on_stream { |_id, _text| called = true }
      # The callback is stored but not invoked until send_task streams
      expect(called).to be false
    end
  end

  describe "register_tools (no-op)" do
    it "accepts tool definitions without error" do
      client.register_tools([{ name: "test" }])
      expect(logs.last).to match(/Registered 1 skill tool/)
    end

    it "does not log for empty definitions" do
      logs.clear
      client.register_tools([])
      expect(logs).to be_empty
    end
  end

  describe "system prompt building" do
    it "uses fallback when system prompt file missing" do
      prompt = client.send(:build_system_prompt, "", "")
      expect(prompt).to include("Skein")
      expect(prompt).to include("personal assistant")
    end

    it "appends memories when non-empty" do
      prompt = client.send(:build_system_prompt, "User likes Ruby", "")
      expect(prompt).to include("Relevant Memories")
      expect(prompt).to include("User likes Ruby")
    end

    it "appends lessons when non-empty" do
      prompt = client.send(:build_system_prompt, "", "Be more concise")
      expect(prompt).to include("Behavioral Lessons")
      expect(prompt).to include("Be more concise")
    end

    it "omits memories section when empty" do
      prompt = client.send(:build_system_prompt, "", "lesson text")
      expect(prompt).not_to include("Relevant Memories")
    end

    it "omits lessons section when empty" do
      prompt = client.send(:build_system_prompt, "memory text", "")
      expect(prompt).not_to include("Behavioral Lessons")
    end
  end

  describe "MCP tool name mapping" do
    it "maps skein_ prefix to mcp__skein__ format" do
      names = client.send(:tool_executor_mcp_names)
      expect(names).to include("mcp__skein__remember")
      expect(names).to include("mcp__skein__recall")
      expect(names).to include("mcp__skein__send_telegram")
      expect(names).to include("mcp__skein__create_reminder")
      expect(names).to include("mcp__skein__write_note")
    end

    it "includes names for all registered tools" do
      names = client.send(:tool_executor_mcp_names)
      expect(names.size).to eq(tool_executor.registered_tool_names.size)
    end
  end

  describe "permission callback" do
    let(:callback) { client.send(:build_permission_callback, "chat-123") }

    it "allows safe builtin tools" do
      Skein::SdkClient::SAFE_BUILTIN_TOOLS.each do |tool|
        result = callback.call(tool, {}, nil)
        expect(result).to be_a(ClaudeAgentSDK::PermissionResultAllow)
      end
    end

    it "denies unknown tools when no channel approval available" do
      allow(channel).to receive(:respond_to?).with(:request_approval).and_return(false)
      result = callback.call("SomeRandomTool", {}, nil)
      expect(result).to be_a(ClaudeAgentSDK::PermissionResultDeny)
    end

    it "routes to channel for non-safe tools when channel supports approval" do
      allow(channel).to receive(:respond_to?).with(:request_approval).and_return(true)
      allow(channel).to receive(:request_approval).with("chat-123", "Bash", {}).and_return("allow")
      result = callback.call("Bash", {}, nil)
      expect(result).to be_a(ClaudeAgentSDK::PermissionResultAllow)
    end

    it "denies when channel denies" do
      allow(channel).to receive(:respond_to?).with(:request_approval).and_return(true)
      allow(channel).to receive(:request_approval).with("chat-123", "Bash", {}).and_return("deny")
      result = callback.call("Bash", {}, nil)
      expect(result).to be_a(ClaudeAgentSDK::PermissionResultDeny)
    end
  end

  describe "auto_approved?" do
    it "returns true when config auto-approves" do
      config_with_rules = Skein::Config.new(
        telegram_token: "fake",
        system_prompt_path: "/nonexistent/prompt.md",
        auto_approve_rules: [Skein::AutoApproveRule.new("skein_remember")]
      )
      custom_client = Skein::SdkClient.new(
        config: config_with_rules, tool_executor: tool_executor,
        channel: channel, logger: logger
      )
      expect(custom_client.send(:auto_approved?, "skein_remember", {}, "chat-1")).to be true
    end

    it "routes to channel when config does not auto-approve" do
      allow(channel).to receive(:respond_to?).with(:request_approval).and_return(true)
      allow(channel).to receive(:request_approval).with("chat-1", "skein_send_telegram", {}).and_return("allow")
      expect(client.send(:auto_approved?, "skein_send_telegram", {}, "chat-1")).to be true
    end

    it "returns false when channel denies" do
      allow(channel).to receive(:respond_to?).with(:request_approval).and_return(true)
      allow(channel).to receive(:request_approval).and_return("deny")
      expect(client.send(:auto_approved?, "skein_send_telegram", {}, "chat-1")).to be false
    end

    it "returns false when no channel approval available" do
      allow(channel).to receive(:respond_to?).with(:request_approval).and_return(false)
      expect(client.send(:auto_approved?, "skein_send_telegram", {}, "chat-1")).to be false
    end
  end

  describe "extraction schemas" do
    it "returns schema for lessons" do
      schema = client.send(:extraction_schema, "lessons")
      expect(schema[:required]).to eq(["lessons"])
      expect(schema[:properties][:lessons][:type]).to eq("array")
    end

    it "returns schema for memories" do
      schema = client.send(:extraction_schema, "memories")
      expect(schema[:required]).to eq(["memories"])
    end

    it "returns schema for summary" do
      schema = client.send(:extraction_schema, "summary")
      expect(schema[:required]).to eq(["summary"])
      expect(schema[:properties][:summary][:type]).to eq("string")
    end

    it "returns schema for consolidate" do
      schema = client.send(:extraction_schema, "consolidate")
      expect(schema[:required]).to eq(["memories"])
    end

    it "raises for unknown type" do
      expect { client.send(:extraction_schema, "unknown") }.to raise_error(ArgumentError, /Unknown extract type/)
    end
  end

  describe "extraction prompts" do
    it "builds lessons prompt" do
      prompt = client.send(:extraction_prompt, "lessons", "some conversation")
      expect(prompt).to include("Extract behavioral lessons")
      expect(prompt).to include("some conversation")
    end

    it "builds memories prompt" do
      prompt = client.send(:extraction_prompt, "memories", "some text")
      expect(prompt).to include("Extract factual memories")
    end

    it "builds summary prompt" do
      prompt = client.send(:extraction_prompt, "summary", "some text")
      expect(prompt).to include("Summarize this conversation")
    end

    it "builds consolidate prompt" do
      prompt = client.send(:extraction_prompt, "consolidate", "some text")
      expect(prompt).to include("Deduplicate and merge")
    end
  end

  describe "decomposition schema" do
    it "has required fields" do
      schema = client.send(:decompose_schema)
      expect(schema[:required]).to eq(%w[decompose subtasks])
      expect(schema[:properties][:decompose][:type]).to eq("boolean")
      expect(schema[:properties][:subtasks][:type]).to eq("array")
    end
  end

  describe "decomposition prompt" do
    it "includes the input text" do
      prompt = client.send(:decompose_prompt, "Build a website")
      expect(prompt).to include("Build a website")
      expect(prompt).to include("decomposed into subtasks")
    end
  end

  describe "extract_text" do
    it "extracts text from assistant message with TextBlocks" do
      msg = ClaudeAgentSDK::AssistantMessage.new(
        content: [
          ClaudeAgentSDK::TextBlock.new(text: "Hello "),
          ClaudeAgentSDK::TextBlock.new(text: "World"),
        ],
        model: "sonnet"
      )
      expect(client.send(:extract_text, msg)).to eq("Hello World")
    end

    it "filters non-text blocks" do
      msg = ClaudeAgentSDK::AssistantMessage.new(
        content: [
          ClaudeAgentSDK::TextBlock.new(text: "Only this"),
          ClaudeAgentSDK::ToolUseBlock.new(id: "tu1", name: "Read", input: {}),
        ],
        model: "sonnet"
      )
      expect(client.send(:extract_text, msg)).to eq("Only this")
    end

    it "returns empty string for message without content method" do
      expect(client.send(:extract_text, Object.new)).to eq("")
    end
  end

  describe "error wrapping" do
    it "wraps CLINotFoundError as SdkError" do
      allow(client).to receive(:build_mcp_server).and_raise(ClaudeAgentSDK::CLINotFoundError)
      expect {
        client.send_task("test", chat_id: "1")
      }.to raise_error(Skein::SdkClient::SdkError, /CLI not found/)
    end

    it "wraps ProcessError as SdkError" do
      error = ClaudeAgentSDK::ProcessError.new("boom")
      allow(error).to receive(:exit_code).and_return(1)
      allow(client).to receive(:build_mcp_server).and_raise(error)
      expect {
        client.send_task("test", chat_id: "1")
      }.to raise_error(Skein::SdkClient::SdkError, /process failed/)
    end

    it "wraps generic errors as SdkError" do
      allow(client).to receive(:build_mcp_server).and_raise(RuntimeError, "unexpected")
      expect {
        client.send_task("test", chat_id: "1")
      }.to raise_error(Skein::SdkClient::SdkError, /SDK error/)
    end
  end

  describe "send_extract error handling" do
    it "returns nil and logs on error" do
      allow(ClaudeAgentSDK).to receive(:query).and_raise(RuntimeError, "connection failed")
      result = client.send_extract("text", extract_type: "lessons", timeout: 1)
      expect(result).to be_nil
      expect(logs.last).to match(/Extraction error.*connection failed/)
    end
  end

  describe "send_decompose error handling" do
    it "returns nil and logs on error" do
      allow(ClaudeAgentSDK).to receive(:query).and_raise(RuntimeError, "connection failed")
      result = client.send_decompose("text", timeout: 1)
      expect(result).to be_nil
      expect(logs.last).to match(/Decompose error.*connection failed/)
    end
  end

  describe "build_mcp_server" do
    it "creates a server with tools from ToolExecutor" do
      server = client.send(:build_mcp_server)
      expect(server).to be_a(Hash)
      expect(server[:type]).to eq("sdk")
      expect(server[:instance]).to respond_to(:list_tools)
    end
  end

  describe "constants" do
    it "defines SAFE_BUILTIN_TOOLS" do
      expect(Skein::SdkClient::SAFE_BUILTIN_TOOLS).to include("Read", "Glob", "Grep")
      expect(Skein::SdkClient::SAFE_BUILTIN_TOOLS).not_to include("Bash", "Write")
    end

    it "defines ALL_BUILTIN_TOOLS as superset of SAFE" do
      Skein::SdkClient::SAFE_BUILTIN_TOOLS.each do |tool|
        expect(Skein::SdkClient::ALL_BUILTIN_TOOLS).to include(tool)
      end
      expect(Skein::SdkClient::ALL_BUILTIN_TOOLS).to include("Bash", "Write", "Edit")
    end
  end
end
