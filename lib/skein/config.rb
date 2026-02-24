module Skein
  class Config
    attr_reader :telegram_token, :db_path,
                :heartbeat_interval, :poll_timeout, :model, :cli_path,
                :task_timeout, :stale_task_timeout,
                :decompose_timeout, :extract_timeout, :summary_timeout, :consolidate_timeout,
                :approval_timeout, :decomposition_min_length, :sdk_max_turns,
                :consolidation_safety_ratio,
                :approval_poll_timeout, :approval_input_preview_length,
                :event_retention_days, :db_busy_timeout_ms,
                :telegram_open_timeout, :telegram_post_read_timeout, :telegram_poll_read_timeout_buffer,
                :embedding_backfill_batch_size,
                :max_context_turns, :summary_threshold, :memory_consolidation_threshold,
                :system_prompt_path, :heartbeat_path,
                :admin_chat_id, :allowed_chat_ids,
                :embedding_model, :embedding_enabled,
                :auto_approve_rules,
                :notes_dir

    # Accept keyword overrides for testability. Overrides take precedence over ENV.
    # Example: Config.new(summary_threshold: 10, max_context_turns: 5)
    def initialize(**overrides)
      @telegram_token     = overrides.fetch(:telegram_token)     { ENV.fetch("SKEIN_TELEGRAM_TOKEN", nil) }
      @db_path            = overrides.fetch(:db_path)            { ENV.fetch("SKEIN_DB_PATH", "data/skein.db") }
      @heartbeat_interval = overrides.fetch(:heartbeat_interval) { ENV.fetch("SKEIN_HEARTBEAT_INTERVAL", "3600").to_i }
      @poll_timeout       = overrides.fetch(:poll_timeout)       { ENV.fetch("SKEIN_POLL_TIMEOUT", "30").to_i }
      @model              = overrides.fetch(:model)              { ENV.fetch("SKEIN_MODEL", "sonnet") }
      raw_cli_path        = overrides.fetch(:cli_path)           { ENV.fetch("SKEIN_CLI_PATH", "~/.local/bin/claude") }
      @cli_path           = File.expand_path(raw_cli_path)
      @task_timeout       = overrides.fetch(:task_timeout)       { ENV.fetch("SKEIN_TASK_TIMEOUT", "300").to_i }
      @stale_task_timeout = overrides.fetch(:stale_task_timeout) { ENV.fetch("SKEIN_STALE_TASK_TIMEOUT", @task_timeout.to_s).to_i }
      @decompose_timeout  = overrides.fetch(:decompose_timeout)  { ENV.fetch("SKEIN_DECOMPOSE_TIMEOUT", "30").to_i }
      @extract_timeout    = overrides.fetch(:extract_timeout)    { ENV.fetch("SKEIN_EXTRACT_TIMEOUT", "30").to_i }
      @summary_timeout    = overrides.fetch(:summary_timeout)    { ENV.fetch("SKEIN_SUMMARY_TIMEOUT", "60").to_i }
      @consolidate_timeout = overrides.fetch(:consolidate_timeout) { ENV.fetch("SKEIN_CONSOLIDATE_TIMEOUT", "120").to_i }
      @approval_timeout   = overrides.fetch(:approval_timeout)   { ENV.fetch("SKEIN_APPROVAL_TIMEOUT", "600").to_i }
      @approval_poll_timeout = overrides.fetch(:approval_poll_timeout) do
        ENV.fetch("SKEIN_APPROVAL_POLL_TIMEOUT", "5").to_i
      end
      @approval_input_preview_length = overrides.fetch(:approval_input_preview_length) do
        ENV.fetch("SKEIN_APPROVAL_INPUT_PREVIEW_LENGTH", "500").to_i
      end
      @decomposition_min_length = overrides.fetch(:decomposition_min_length) { ENV.fetch("SKEIN_DECOMPOSITION_MIN_LENGTH", "80").to_i }
      @sdk_max_turns      = overrides.fetch(:sdk_max_turns)      { ENV.fetch("SKEIN_SDK_MAX_TURNS", "50").to_i }
      @consolidation_safety_ratio = overrides.fetch(:consolidation_safety_ratio) do
        ENV.fetch("SKEIN_CONSOLIDATION_SAFETY_RATIO", "0.3").to_f
      end
      @event_retention_days = overrides.fetch(:event_retention_days) do
        ENV.fetch("SKEIN_EVENT_RETENTION_DAYS", "30").to_i
      end
      @db_busy_timeout_ms = overrides.fetch(:db_busy_timeout_ms) do
        ENV.fetch("SKEIN_DB_BUSY_TIMEOUT_MS", "5000").to_i
      end
      @telegram_open_timeout = overrides.fetch(:telegram_open_timeout) do
        ENV.fetch("SKEIN_TELEGRAM_OPEN_TIMEOUT", "10").to_i
      end
      @telegram_post_read_timeout = overrides.fetch(:telegram_post_read_timeout) do
        ENV.fetch("SKEIN_TELEGRAM_POST_READ_TIMEOUT", "30").to_i
      end
      @telegram_poll_read_timeout_buffer = overrides.fetch(:telegram_poll_read_timeout_buffer) do
        ENV.fetch("SKEIN_TELEGRAM_POLL_READ_TIMEOUT_BUFFER", "5").to_i
      end
      @embedding_backfill_batch_size = overrides.fetch(:embedding_backfill_batch_size) do
        ENV.fetch("SKEIN_EMBEDDING_BACKFILL_BATCH_SIZE", "50").to_i
      end
      @max_context_turns  = overrides.fetch(:max_context_turns)  { ENV.fetch("SKEIN_MAX_CONTEXT_TURNS", "20").to_i }
      @summary_threshold  = overrides.fetch(:summary_threshold)  { ENV.fetch("SKEIN_SUMMARY_THRESHOLD", "40").to_i }
      @memory_consolidation_threshold = overrides.fetch(:memory_consolidation_threshold) { ENV.fetch("SKEIN_MEMORY_CONSOLIDATION_THRESHOLD", "100").to_i }
      @system_prompt_path = overrides.fetch(:system_prompt_path) { ENV.fetch("SKEIN_SYSTEM_PROMPT", "docs/SYSTEM_PROMPT.md") }
      @heartbeat_path     = overrides.fetch(:heartbeat_path)     { ENV.fetch("SKEIN_HEARTBEAT_PATH", "docs/HEARTBEAT.md") }
      @admin_chat_id      = overrides.fetch(:admin_chat_id)      { ENV["SKEIN_ADMIN_CHAT_ID"] }
      @allowed_chat_ids   = overrides.fetch(:allowed_chat_ids)   { parse_allowed_chat_ids }
      @embedding_model    = overrides.fetch(:embedding_model)    { ENV.fetch("SKEIN_EMBEDDING_MODEL", "sentence-transformers/all-MiniLM-L6-v2") }
      @embedding_enabled  = overrides.fetch(:embedding_enabled)  { ENV.fetch("SKEIN_EMBEDDING_ENABLED", "true") == "true" }
      @notes_dir          = overrides.fetch(:notes_dir)          { ENV.fetch("SKEIN_NOTES_DIR", "docs/notes") }
      @auto_approve_rules = overrides.fetch(:auto_approve_rules) { parse_auto_approve_rules }
    end

    def chat_allowed?(chat_id)
      @allowed_chat_ids.empty? || @allowed_chat_ids.include?(chat_id.to_s)
    end

    # Check if a tool invocation should be auto-approved.
    # Returns true if any rule matches.
    #
    # Rules are parsed from SKEIN_AUTO_APPROVE env var:
    #   "Bash"          — auto-approve all Bash calls
    #   "Bash:ls *"     — auto-approve Bash only when command matches glob
    #   "Write:docs/*"  — auto-approve Write only for paths under docs/
    #   "*"             — auto-approve everything (YOLO mode)
    #
    def auto_approve?(tool_name, tool_input = {})
      @auto_approve_rules.any? { |rule| rule.matches?(tool_name, tool_input) }
    end

    private

    def parse_allowed_chat_ids
      raw = ENV["SKEIN_ALLOWED_CHAT_IDS"]
      return [] unless raw
      raw.split(",").map(&:strip).reject(&:empty?)
    end

    def parse_auto_approve_rules
      raw = ENV["SKEIN_AUTO_APPROVE"]
      return [] unless raw
      raw.split(",").map(&:strip).reject(&:empty?).map do |spec|
        AutoApproveRule.parse(spec)
      end
    end
  end

  # A single auto-approve rule. Matches a tool name and optionally
  # constrains by a glob pattern on a relevant input field.
  class AutoApproveRule
    attr_reader :tool_pattern, :input_pattern

    def initialize(tool_pattern, input_pattern = nil)
      @tool_pattern = tool_pattern
      @input_pattern = input_pattern
    end

    # Parse a rule spec like "Bash", "Bash:ls *", "Write:docs/*", "*"
    def self.parse(spec)
      if spec.include?(":")
        tool, pattern = spec.split(":", 2)
        new(tool.strip, pattern.strip)
      else
        new(spec.strip)
      end
    end

    # Check if this rule matches the given tool invocation.
    def matches?(tool_name, tool_input = {})
      return false unless tool_name_matches?(tool_name)
      return true unless @input_pattern

      # Match against the most relevant input field for the tool
      relevant_value = extract_relevant_value(tool_name, tool_input)
      return false unless relevant_value

      File.fnmatch?(@input_pattern, relevant_value, File::FNM_DOTMATCH)
    end

    private

    def tool_name_matches?(tool_name)
      @tool_pattern == "*" || @tool_pattern == tool_name
    end

    # Extract the value to match against for input-constrained rules.
    # Each tool has a primary input field that determines the "scope".
    def extract_relevant_value(tool_name, tool_input)
      return nil unless tool_input.is_a?(Hash)

      case tool_name
      when "Bash"
        tool_input["command"] || tool_input[:command]
      when "Write", "Edit", "Read"
        tool_input["file_path"] || tool_input["filePath"] ||
          tool_input[:file_path] || tool_input[:filePath]
      else
        # For unknown tools, try common field names
        tool_input["command"] || tool_input["path"] ||
          tool_input["file_path"] || tool_input.values.first
      end
    end
  end
end
