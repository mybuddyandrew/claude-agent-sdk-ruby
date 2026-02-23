require "json"

module Skein
  # ToolExecutor handles tool_call messages from the Python bridge.
  #
  # When the bridge's MCP tools are invoked by the SDK, they delegate to Ruby
  # via the pipe protocol. ToolExecutor maps MCP tool names (skein_remember, etc.)
  # to the actual Ruby tool implementations and executes them.
  #
  # It also determines which tools require user approval (side-effecting tools).
  #
  # The tool registry is mutable — skills can register additional tools at boot.
  #
  class ToolExecutor
    # Default built-in tools. Skills can add more via register_tool.
    BUILTIN_TOOLS = {
      "skein_remember"        => -> { Tools::Remember },
      "skein_recall"          => -> { Tools::Recall },
      "skein_send_telegram"   => -> { Tools::SendTelegram },
      "skein_create_reminder" => -> { Tools::CreateReminder },
      "skein_write_note"      => -> { Tools::WriteNote },
    }.freeze

    BUILTIN_APPROVAL_REQUIRED = %w[
      skein_send_telegram
      skein_create_reminder
      skein_write_note
    ].freeze

    def initialize(memory:, timers:, config: nil, channel_context: {})
      @memory = memory
      @timers = timers
      @config = config
      @channel_context = channel_context  # e.g. { telegram: <instance> }
      @tool_map = BUILTIN_TOOLS.dup
      @approval_required = BUILTIN_APPROVAL_REQUIRED.dup
    end

    # Register a new tool at runtime (e.g. from a skill).
    # tool_name: MCP name (e.g. "skein_my_tool")
    # tool_module: Ruby module with .definition, .execute, .requires_approval?
    def register_tool(tool_name, tool_module)
      @tool_map[tool_name] = -> { tool_module }
      @approval_required << tool_name if tool_module.requires_approval?
    end

    # Update channel context (e.g. when switching channels)
    def channel_context=(ctx)
      @channel_context = ctx
    end

    # Execute a tool by MCP name. Returns the result string.
    # Raises KeyError if the tool name is unknown.
    def execute(tool_name, tool_input, chat_id:, task_id: nil)
      loader = @tool_map[tool_name]
      raise KeyError, "Unknown tool: #{tool_name}" unless loader

      tool_module = loader.call
      context = build_context(chat_id: chat_id, task_id: task_id)
      tool_module.execute(tool_input, **context)
    end

    def requires_approval?(tool_name)
      @approval_required.include?(tool_name)
    end

    def known_tool?(tool_name)
      @tool_map.key?(tool_name)
    end

    # Return all registered tool names (for bridge registration).
    def registered_tool_names
      @tool_map.keys
    end

    private

    def build_context(chat_id:, task_id:)
      ctx = {
        memory: @memory,
        timers: @timers,
        config: @config,
        chat_id: chat_id,
        task_id: task_id,
      }
      ctx.merge!(@channel_context)
      ctx
    end
  end
end
