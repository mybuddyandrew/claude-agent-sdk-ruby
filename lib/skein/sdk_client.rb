require "claude_agent_sdk"
require "async"
require "timeout"

module Skein
  # SdkClient wraps the Ruby Claude Agent SDK.
  #
  # It handles:
  # - Task execution via ClaudeAgentSDK::Client (with permission callbacks)
  # - Structured extraction via ClaudeAgentSDK.query (lessons, memories, summaries)
  # - Task decomposition via ClaudeAgentSDK.query (structured output)
  # - MCP tool server built from ToolExecutor's registry
  # - Session resumption via SDK's resume option
  # - Streaming via include_partial_messages
  #
  class SdkClient
    class SdkError < StandardError; end

    CLI_PATH = File.expand_path("~/.local/bin/claude")

    SAFE_BUILTIN_TOOLS = %w[Read Glob Grep WebFetch WebSearch Task].freeze
    ALL_BUILTIN_TOOLS  = (SAFE_BUILTIN_TOOLS + %w[Bash Write Edit]).freeze

    attr_reader :running

    def initialize(config:, tool_executor:, channel:, logger: nil)
      @config = config
      @tool_executor = tool_executor
      @channel = channel
      @logger = logger
      @running = false

      # Callbacks — set by Agent via on_stream
      @on_stream = nil

      # Per-task state
      @current_chat_id = nil
      @current_task_id = nil
    end

    # -- Callbacks --------------------------------------------------------

    def on_stream(&block)
      @on_stream = block
    end

    # -- Lifecycle --------------------------------------------------------

    def start
      @running = true
      log "SDK client started (cli: #{CLI_PATH})"
    end

    def shutdown
      @running = false
      log "SDK client stopped"
    end

    def alive?
      @running
    end

    # -- Task execution ---------------------------------------------------

    # Execute a task through the Claude SDK.
    # Returns a result hash: { "type" => "result", "text" => "...", "session_id" => "..." }
    def send_task(input, chat_id:, session_id: nil, memories: "", lessons: "", timeout: 300)
      @current_chat_id = chat_id
      @current_task_id = nil  # set by caller if needed

      mcp_server = build_mcp_server
      system_prompt = build_system_prompt(memories, lessons)

      # Build allowed tools: MCP tools + built-in tools
      mcp_tool_names = tool_executor_mcp_names
      allowed = mcp_tool_names + ALL_BUILTIN_TOOLS

      result_text = ""
      final_session_id = nil
      last_streamed_len = 0

      Async do
        options = ClaudeAgentSDK::ClaudeAgentOptions.new(
          cli_path: CLI_PATH,
          system_prompt: system_prompt,
          mcp_servers: { skein: mcp_server },
          allowed_tools: allowed,
          can_use_tool: build_permission_callback(chat_id),
          permission_mode: "bypassPermissions",
          resume: session_id,
          max_turns: 50,
          include_partial_messages: true,
        )

        client = ClaudeAgentSDK::Client.new(options: options)
        client.connect(input)

        client.receive_response do |msg|
          case msg
          when ClaudeAgentSDK::AssistantMessage
            text = extract_text(msg)
            if text && text.length > last_streamed_len
              delta = text[last_streamed_len..]
              @on_stream&.call(@current_task_id, delta) if delta && !delta.empty?
              last_streamed_len = text.length
            end
            result_text = text if text && !text.empty?

          when ClaudeAgentSDK::ResultMessage
            final_session_id = msg.session_id
            result_text = msg.result || result_text
            log "Task completed: #{msg.num_turns} turns, $#{msg.total_cost_usd || 0}"
          end
        end

        client.disconnect
      end.wait

      {
        "type" => "result",
        "text" => result_text,
        "session_id" => final_session_id,
        "structured_output" => nil,
      }
    rescue ClaudeAgentSDK::CLINotFoundError
      raise SdkError, "Claude CLI not found at #{CLI_PATH}"
    rescue ClaudeAgentSDK::ProcessError => e
      raise SdkError, "Claude process failed: #{e.message} (exit #{e.exit_code})"
    rescue => e
      raise SdkError, "SDK error: #{e.message}"
    end

    # -- Extraction (structured output) ------------------------------------

    # Extract structured data from conversation text.
    # Returns parsed JSON hash or nil on error.
    def send_extract(conversation_text, extract_type: "lessons", timeout: 60)
      schema = extraction_schema(extract_type)
      prompt = extraction_prompt(extract_type, conversation_text)

      result = nil
      Timeout.timeout(timeout) do
        ClaudeAgentSDK.query(
          prompt: prompt,
          options: ClaudeAgentSDK::ClaudeAgentOptions.new(
            cli_path: CLI_PATH,
            model: @config.model,
            system_prompt: "You are a precise extraction assistant. Return only the requested structured data.",
            output_format: { type: "json_schema", schema: schema },
            max_turns: 2,
            permission_mode: "bypassPermissions",
          )
        ) do |msg|
          if msg.is_a?(ClaudeAgentSDK::ResultMessage) && msg.structured_output
            result = msg.structured_output
          end
        end
      end

      result
    rescue => e
      log "Extraction error (#{extract_type}): #{e.message}"
      nil
    end

    # -- Task decomposition ------------------------------------------------

    # Check if a task should be decomposed into subtasks.
    # Returns structured output hash or nil.
    def send_decompose(input_text, timeout: 30)
      result = nil
      Timeout.timeout(timeout) do
        ClaudeAgentSDK.query(
          prompt: decompose_prompt(input_text),
          options: ClaudeAgentSDK::ClaudeAgentOptions.new(
            cli_path: CLI_PATH,
            model: @config.model,
            system_prompt: "You are a task planning assistant. Analyze whether the request should be decomposed.",
            output_format: { type: "json_schema", schema: decompose_schema },
            max_turns: 2,
            permission_mode: "bypassPermissions",
          )
        ) do |msg|
          if msg.is_a?(ClaudeAgentSDK::ResultMessage) && msg.structured_output
            result = msg.structured_output
          end
        end
      end

      result
    rescue => e
      log "Decompose error: #{e.message}"
      nil
    end

    # -- Dynamic tool registration -----------------------------------------

    # No-op — tools are built fresh from ToolExecutor each task.
    # Kept for API compatibility with SkillRegistry.
    def register_tools(tool_definitions)
      log "Registered #{tool_definitions.size} skill tool(s)" if tool_definitions.any?
    end

    private

    # -- MCP Server --------------------------------------------------------

    def build_mcp_server
      tools = []

      @tool_executor.each_tool do |mcp_name, tool_mod|
        defn = tool_mod.definition

        # Capture for closure
        executor = @tool_executor
        client_ref = self
        chat_id_ref = -> { @current_chat_id }
        task_id_ref = -> { @current_task_id }

        tool = ClaudeAgentSDK.create_tool(
          defn[:name].to_s,
          defn[:description].to_s,
          defn[:input_schema] || { type: "object" }
        ) do |args|
          # Convert symbol keys to string keys for tool execution
          string_args = args.transform_keys(&:to_s)

          # Check approval for tools that require it
          if executor.requires_approval?(mcp_name)
            unless client_ref.send(:auto_approved?, mcp_name, string_args, chat_id_ref.call)
              next { content: [{ type: "text", text: "Tool denied by user: #{mcp_name}" }], is_error: true }
            end
          end

          # Execute directly in-process via ToolExecutor
          result = executor.execute(mcp_name, string_args,
                                    chat_id: chat_id_ref.call,
                                    task_id: task_id_ref.call)
          { content: [{ type: "text", text: result.to_s }] }
        end

        tools << tool
      end

      ClaudeAgentSDK.create_sdk_mcp_server(
        name: "skein", version: "0.1.0", tools: tools
      )
    end

    def tool_executor_mcp_names
      @tool_executor.registered_tool_names.map do |name|
        # skein_remember -> mcp__skein__remember
        short_name = name.delete_prefix("skein_")
        "mcp__skein__#{short_name}"
      end
    end

    # -- Permission callback -----------------------------------------------

    def build_permission_callback(chat_id)
      config = @config
      channel = @channel

      ->(tool_name, tool_input, _context) {
        # Safe built-in tools: always allow
        if SAFE_BUILTIN_TOOLS.include?(tool_name)
          return ClaudeAgentSDK::PermissionResultAllow.new
        end

        # Check auto-approve rules from config
        if config.auto_approve?(tool_name, tool_input)
          return ClaudeAgentSDK::PermissionResultAllow.new
        end

        # Route to channel for interactive approval
        if channel.respond_to?(:request_approval)
          decision = channel.request_approval(chat_id, tool_name, tool_input)
          if decision == "allow"
            return ClaudeAgentSDK::PermissionResultAllow.new
          else
            return ClaudeAgentSDK::PermissionResultDeny.new(
              message: "User denied tool: #{tool_name}",
              interrupt: false
            )
          end
        end

        # No channel approval — deny by default
        ClaudeAgentSDK::PermissionResultDeny.new(
          message: "No approval mechanism available",
          interrupt: false
        )
      }
    end

    # -- Approval for domain tools -----------------------------------------

    def auto_approved?(tool_name, tool_input, chat_id)
      return true if @config.auto_approve?(tool_name, tool_input)

      if @channel.respond_to?(:request_approval)
        decision = @channel.request_approval(chat_id, tool_name, tool_input)
        return decision == "allow"
      end

      false
    end

    # -- System prompt -----------------------------------------------------

    def build_system_prompt(memories, lessons)
      parts = []

      begin
        parts << File.read(@config.system_prompt_path).strip
      rescue Errno::ENOENT
        parts << "You are Skein, a personal assistant agent kernel. Be concise and direct."
      end

      parts << "\n## Relevant Memories\n#{memories}" unless memories.empty?
      parts << "\n## Behavioral Lessons\n#{lessons}" unless lessons.empty?

      parts.join("\n")
    end

    # -- Text extraction ---------------------------------------------------

    def extract_text(msg)
      return "" unless msg.respond_to?(:content)
      msg.content
        .select { |b| b.is_a?(ClaudeAgentSDK::TextBlock) }
        .map(&:text)
        .join
    end

    # -- Extraction schemas & prompts --------------------------------------

    def extraction_schema(type)
      case type
      when "lessons"
        {
          type: "object",
          properties: {
            lessons: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  content: { type: "string" },
                  category: { type: "string", enum: %w[tone tool_use context proactivity error_recovery] },
                },
                required: %w[content category],
              },
            },
          },
          required: ["lessons"],
        }
      when "memories"
        {
          type: "object",
          properties: {
            memories: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  content: { type: "string" },
                  category: { type: "string" },
                },
                required: %w[content],
              },
            },
          },
          required: ["memories"],
        }
      when "summary"
        {
          type: "object",
          properties: {
            summary: { type: "string" },
          },
          required: ["summary"],
        }
      when "consolidate"
        {
          type: "object",
          properties: {
            memories: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  content: { type: "string" },
                  category: { type: "string" },
                },
                required: %w[content],
              },
            },
          },
          required: ["memories"],
        }
      else
        raise ArgumentError, "Unknown extract type: #{type}"
      end
    end

    def extraction_prompt(type, text)
      case type
      when "lessons"
        "Extract behavioral lessons from this conversation. What should the assistant do differently?\n\n#{text}"
      when "memories"
        "Extract factual memories worth remembering from this conversation.\n\n#{text}"
      when "summary"
        "Summarize this conversation concisely, preserving key context.\n\n#{text}"
      when "consolidate"
        "Deduplicate and merge these memories, combining related facts. Keep all unique information.\n\n#{text}"
      end
    end

    def decompose_schema
      {
        type: "object",
        properties: {
          decompose: { type: "boolean" },
          subtasks: {
            type: "array",
            items: {
              type: "object",
              properties: {
                title: { type: "string" },
                input: { type: "string" },
              },
              required: %w[title input],
            },
          },
        },
        required: %w[decompose subtasks],
      }
    end

    def decompose_prompt(input_text)
      "Should this request be decomposed into subtasks? If yes, provide 2-8 subtasks. " \
      "If it's a simple request, set decompose=false.\n\nRequest: #{input_text}"
    end

    def log(msg)
      @logger&.call("[SdkClient] #{msg}")
    end
  end
end
