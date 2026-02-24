require "json"
require_relative "runtime_helpers"

module Skein
  class Kernel
    include RuntimeHelpers

    def initialize
      @config    = Config.new

      unless @config.telegram_token && !@config.telegram_token.empty?
        raise ArgumentError, "SKEIN_TELEGRAM_TOKEN is required. Set it in .env or your environment."
      end

      @db        = DB.new(@config.db_path, busy_timeout_ms: @config.db_busy_timeout_ms)
      @events    = EventStore.new(@db)
      @tasks     = Task.new(db: @db, event_store: @events)
      @timers    = Timer.new(db: @db, event_store: @events)
      @embedder  = build_embedder
      @memory    = Memory.new(db: @db, event_store: @events, embedder: @embedder)
      @lessons   = Lesson.new(db: @db, event_store: @events)
      @lane      = Lane.new(task: @tasks)
      @telegram  = Activities::Telegram.new(
        token: @config.telegram_token,
        open_timeout: @config.telegram_open_timeout,
        post_read_timeout: @config.telegram_post_read_timeout,
        poll_read_timeout_buffer: @config.telegram_poll_read_timeout_buffer
      )

      # SDK client + tool executor + skills
      tool_executor = ToolExecutor.new(
        memory: @memory, timers: @timers, config: @config,
        channel_context: tool_context
      )

      @skill_registry = SkillRegistry.new(
        context: skill_context, logger: method(:log)
      )
      @skill_registry.load_all!
      @skill_registry.register_tools!(tool_executor)

      sdk_client = SdkClient.new(
        config: @config, tool_executor: tool_executor,
        channel: self, logger: method(:log)
      )

      @agent = Agent.new(
        config: @config, db: @db, events: @events, tasks: @tasks,
        timers: @timers, memory: @memory, lessons: @lessons,
        sdk_client: sdk_client, tool_executor: tool_executor,
        skill_registry: @skill_registry,
        channel: self, logger: method(:log)
      )

      @dispatcher = build_dispatcher

      @queued_updates = []
      @running = true

      setup_signal_handlers!
      @agent.start_sdk
      @agent.recover_stale_tasks!
      ensure_heartbeat_timer!
      @skill_registry.setup_schedules!
      @agent.maintenance!
    end

    def run
      log "Kernel started. Polling Telegram..."
      while @running
        tick
      end
      @dispatcher.shutdown
      @agent.stop_sdk
      log "Kernel stopped."
    end

    # --- Channel Adapter Interface ---

    TELEGRAM_MAX_LENGTH = 4096

    def send_reply(chat_id, text)
      return unless chat_id

      # Telegram has a 4096 char limit per message — split long responses
      if text.length <= TELEGRAM_MAX_LENGTH
        @telegram.send_message(chat_id: chat_id, text: text)
      else
        chunks = split_message(text, TELEGRAM_MAX_LENGTH)
        chunks.each { |chunk| @telegram.send_message(chat_id: chat_id, text: chunk) }
      end
    rescue StandardError => e
      log "Telegram send error: #{e.message}"
    end

    # Called by the SDK (via Agent) when a tool needs approval.
    # For Telegram, this blocks while polling for /approve or /deny.
    def request_approval(chat_id, tool_name, tool_input)
      input_summary = tool_input.is_a?(Hash) ? JSON.generate(tool_input) : tool_input.to_s
      # Truncate input summary for readability
      max_len = @config.approval_input_preview_length
      input_summary = input_summary[0...max_len] + "..." if input_summary.length > max_len
      msg = "I'd like to use:\n  #{tool_name}(#{input_summary})\n\nReply /approve or /deny"
      send_reply(chat_id, msg)

      # Poll Telegram for the approval response with timeout
      deadline = Time.now + @config.approval_timeout
      loop do
        return "deny" if Time.now > deadline

        updates = @telegram.poll(timeout: @config.approval_poll_timeout)
        updates.each do |update|
          msg_data = update.dig("message")
          next unless msg_data
          text = msg_data.dig("text")
          next unless text
          update_chat_id = msg_data.dig("chat", "id").to_s
          unless update_chat_id == chat_id.to_s
            # Message for another chat while this approval is waiting.
            # Queue it so main ingestion handles it later.
            @queued_updates << update
            next
          end

          if text.start_with?("/approve")
            return "allow"
          elsif text.start_with?("/deny")
            return "deny"
          else
            # Non-approval message during approval wait — queue for later
            @queued_updates << update
          end
        end
      end
    end

    def tool_context
      { telegram: @telegram }
    end

    private

    def tick
      process_timers

      # Drain any updates that arrived during an approval wait
      unless @queued_updates.empty?
        queued = @queued_updates.dup
        @queued_updates.clear
        ingest_telegram_updates(queued)
      end

      updates = @telegram.poll(timeout: @config.poll_timeout)
      ingest_telegram_updates(updates)
      process_next_task
    end

    # --- Timers ---

    def process_timers
      @timers.due_timers.each do |timer|
        case timer["name"]
        when "heartbeat"
          run_heartbeat(timer)
        when /\Askill:/
          run_skill_timer(timer)
        else
          run_custom_timer(timer)
        end
        @timers.mark_fired!(timer["id"])
      end
    end

    def run_skill_timer(timer)
      @skill_registry.handle_timer(timer)
    rescue StandardError => e
      log "Skill timer error: #{e.message}"
    end

    def run_heartbeat(timer)
      # Heartbeat goes through the SDK like any other task
      checklist = begin
        File.read(@config.heartbeat_path)
      rescue Errno::ENOENT
        "No heartbeat checklist found."
      end

      task_id = @tasks.create(
        source: "heartbeat", lane: Lane::L0_INTERRUPT,
        input_text: "Run heartbeat check:\n#{checklist}"
      )
      # The dispatcher will pick it up and process it through the SDK
    end

    def run_custom_timer(timer)
      payload = timer["payload"]
      payload = JSON.parse(payload) if payload.is_a?(String)
      chat_id = payload["chat_id"]
      text = payload["text"]
      return unless chat_id && text

      task_id = @tasks.create(source: "timer", chat_id: chat_id, input_text: text, lane: Lane::L1_INTERACTIVE)
      @tasks.transition!(task_id, "running")

      begin
        @telegram.send_message(chat_id: chat_id, text: "Reminder: #{text}")
        @tasks.transition!(task_id, "completed", result_text: "Reminder delivered")
      rescue StandardError => e
        log "Timer delivery error: #{e.message}"
        @tasks.transition!(task_id, "failed", error_message: e.message)
      end
    end

    # --- Telegram Ingestion ---

    def ingest_telegram_updates(updates)
      updates.each do |update|
        msg = update.dig("message")
        next unless msg
        text = msg.dig("text")
        next unless text

        chat_id = msg.dig("chat", "id").to_s
        from_name = msg.dig("from", "first_name") || "Unknown"

        unless @config.chat_allowed?(chat_id)
          log "Ignored message from unauthorized chat_id=#{chat_id}"
          next
        end

        @events.append(type: "telegram_message_received", payload: {
          chat_id: chat_id, text: text, from: from_name
        })

        # Approval commands are now handled inline in request_approval
        # (request_approval blocks waiting for the response)
        unless text.start_with?("/approve", "/deny")
          @tasks.create(source: "telegram", chat_id: chat_id, input_text: text)
        end
      end
    end

    # --- Task Processing ---

    def process_next_task
      @dispatcher.tick
    end

    # --- Setup ---

    def ensure_heartbeat_timer!
      existing = @timers.find_by_name("heartbeat")
      return if existing

      @timers.create(
        name: "heartbeat",
        next_fire_at: Time.now.utc + @config.heartbeat_interval,
        interval_seconds: @config.heartbeat_interval
      )
      log "Heartbeat timer created (interval: #{@config.heartbeat_interval}s)"
    end

    def setup_signal_handlers!
      Signal.trap("INT")  { @running = false }
      Signal.trap("TERM") { @running = false }
    end

    def build_dispatcher
      log "Using sequential dispatcher"
      Dispatcher::Sequential.new(
        lane: @lane, tasks: @tasks, agent: @agent, logger: method(:log)
      )
    end

    # Split a long message into chunks that fit within Telegram's limit.
    # Prefers splitting at newline boundaries; falls back to hard cut.
    def split_message(text, max_length)
      chunks = []
      remaining = text
      while remaining.length > max_length
        # Try to find the last newline within the limit
        cut = remaining.rindex("\n", max_length)
        cut = max_length if cut.nil? || cut == 0
        chunks << remaining[0...cut]
        remaining = remaining[cut..].lstrip
      end
      chunks << remaining unless remaining.empty?
      chunks
    end

    def log(msg)
      $stdout.puts "[Skein] #{Time.now.utc.iso8601} #{msg}"
    end
  end
end
