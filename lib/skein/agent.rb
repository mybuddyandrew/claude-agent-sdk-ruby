require "json"

module Skein
  class Agent
    attr_reader :config, :db, :events, :tasks, :timers, :memory, :lessons

    # channel: must respond to:
    #   #send_reply(chat_id, text)
    #   #request_approval(chat_id, tool_name, tool_input) -> "allow" or "deny"
    # sdk_client: Skein::SdkClient instance (wraps the Ruby Claude Agent SDK)
    # tool_executor: Skein::ToolExecutor instance (executes domain tools)
    # logger: must respond to #call(message)
    def initialize(config:, db:, events:, tasks:, timers:, memory:, lessons:,
                   sdk_client:, tool_executor:, channel:, skill_registry: nil, logger: nil)
      @config         = config
      @db             = db
      @events         = events
      @tasks          = tasks
      @timers         = timers
      @memory         = memory
      @lessons        = lessons
      @sdk_client     = sdk_client
      @tool_executor  = tool_executor
      @channel        = channel
      @skill_registry = skill_registry
      @logger         = logger || method(:default_log)

      wire_streaming!
    end

    # --- SDK Lifecycle ---

    def start_sdk
      @sdk_client.start
      log "SDK client started"
    end

    def stop_sdk
      @sdk_client.shutdown
      log "SDK client stopped"
    end

    # --- Core Task Processing ---

    def process_task(task)
      task_id = task["id"]
      chat_id = task["chat_id"]
      input_text = task["input_text"]

      # Store the user turn (idempotent — callers no longer need to do this).
      if chat_id && input_text && !input_text.empty?
        store_turn(chat_id: chat_id, role: "user", content: input_text, task_id: task_id)
      end

      # Check if this task should be decomposed into subtasks.
      # Skip decomposition for: subtasks, short inputs, or non-interactive tasks.
      if should_decompose?(task)
        return if try_decompose(task)
        # If decomposition failed or returned false, process directly
      end

      # Set context for SDK client (tools need to know active task/chat).
      @active_chat_id = chat_id
      @sdk_client.current_task_id = task_id

      # Build context for the SDK
      memories_text = @memory.format_for_prompt(limit: 20) || ""
      lessons_text  = @lessons.format_for_prompt(limit: 10) || ""
      session_id    = load_session(chat_id)

      # If no session exists, include conversation summary for continuity
      unless session_id
        summary = load_summary(chat_id)
        if summary
          memories_text = "## Conversation Summary\n#{summary}\n\n#{memories_text}"
        end
      end

      @events.append(type: "sdk_request_sent", task_id: task_id, payload: {
        chat_id: chat_id, has_session: !session_id.nil?
      })

      begin
        result = @sdk_client.send_task(
          input_text,
          chat_id:    chat_id,
          session_id: session_id,
          memories:   memories_text,
          lessons:    lessons_text,
          timeout:    @config.task_timeout
        )
      rescue SdkClient::SdkError => e
        log "SDK error for task #{task_id}: #{e.message}"
        @tasks.transition!(task_id, "failed", error_message: e.message)
        @events.append(type: "error_occurred", task_id: task_id, payload: { error: e.message })
        return
      end

      # Store the session for future continuity (persisted to DB)
      if result["session_id"] && !result["session_id"].empty?
        save_session(chat_id, result["session_id"])
      end

      reply = result["text"] || ""

      @events.append(type: "sdk_response_received", task_id: task_id, payload: {
        session_id: result["session_id"],
        text_length: reply.length
      })

      # If the channel supports streaming, it already got the text progressively.
      # Send stream_end to finalize, then store the turn.
      # If no streaming support, send the full reply at once.
      if chat_id && !reply.empty?
        if @channel.respond_to?(:stream_text)
          @channel.stream_end(chat_id) if @channel.respond_to?(:stream_end)
        else
          @channel.send_reply(chat_id, reply)
        end
        store_turn(chat_id: chat_id, role: "assistant", content: reply, task_id: task_id)
      end

      @tasks.transition!(task_id, "completed", result_text: reply)

      # Skill hooks: after_task
      @skill_registry&.run_after_task(task, reply)

      # Background extraction: extract lessons and memories from this conversation
      extract_learnings(chat_id: chat_id, task_id: task_id)

      # Summarize old turns if the conversation is getting long
      maybe_summarize_turns(chat_id)

      # Subtask parent completion check
      if task["parent_task_id"]
        check_parent_completion(task)
      end
    end

    # --- Conversation History ---

    def store_turn(chat_id:, role:, content:, task_id: nil)
      @db.execute(
        "INSERT INTO conversation_turns (chat_id, role, content, task_id) VALUES (?, ?, ?, ?)",
        [chat_id, role, content, task_id]
      )
    end

    def recent_turns(chat_id:)
      return [] unless chat_id
      @db.execute(
        "SELECT * FROM conversation_turns WHERE chat_id = ? ORDER BY id DESC LIMIT ?",
        [chat_id, @config.max_context_turns]
      ).reverse
    end

    # --- Recovery & Maintenance ---

    def recover_stale_tasks!
      stale_cutoff = (Time.now.utc - @config.stale_task_timeout).strftime("%Y-%m-%dT%H:%M:%S.%L")
      stale = @db.execute(
        "SELECT * FROM tasks WHERE state = 'running' AND updated_at < ?",
        [stale_cutoff]
      )
      stale.each do |task|
        log "Recovering stale task #{task['id']}"
        @tasks.transition!(task["id"], "failed", error_message: "Stale: interrupted by restart")
        @events.append(type: "error_occurred", task_id: task["id"], payload: {
          error: "Task was running when process restarted"
        })
      end
    end

    def maintenance!
      pruned = @lessons.prune!
      log "Pruned #{pruned} ineffective lessons" if pruned > 0

      event_pruned = @events.prune!(days: @config.event_retention_days)
      if event_pruned > 0
        log "Pruned #{event_pruned} events older than #{@config.event_retention_days} days"
      end

      consolidate_memories!

      backfilled = @memory.backfill_embeddings(batch_size: @config.embedding_backfill_batch_size)
      log "Backfilled embeddings for #{backfilled} memories" if backfilled.positive?

      # Skill hooks: on_maintenance
      @skill_registry&.run_maintenance
    end

    # Consolidate memories when the count exceeds the threshold.
    # Sends all memories to the SDK for deduplication and merging,
    # then replaces the entire memory store with the consolidated result.
    def consolidate_memories!
      threshold = @config.memory_consolidation_threshold
      current_count = @memory.count
      return if current_count <= threshold

      log "Memory consolidation: #{current_count} memories exceed threshold of #{threshold}"

      # Fetch all memories
      all_memories = @memory.top(limit: current_count + 100)
      return if all_memories.empty?

      # Format for extraction
      lines = all_memories.map do |m|
        tag = m["category"] ? " [#{m['category']}]" : ""
        "- #{m['content']}#{tag}"
      end
      input_text = lines.join("\n")

      result = @sdk_client.send_extract(
        input_text,
        extract_type: "consolidate",
        timeout: @config.consolidate_timeout
      )
      return unless result.is_a?(Hash) && result["memories"].is_a?(Array)

      consolidated = result["memories"]

      # Safety check: if consolidated is below the configured ratio, something went wrong
      min_allowed = (current_count * @config.consolidation_safety_ratio).ceil
      if consolidated.size < min_allowed
        pct = (@config.consolidation_safety_ratio * 100).round
        log "Memory consolidation aborted: consolidated #{consolidated.size} from #{current_count} (below #{pct}% safety threshold)"
        return
      end

      # Replace memories in a transaction.
      # Use direct SQL deletes instead of memory.forget to avoid
      # swallowing exceptions inside the transaction (forget catches
      # SQLite3::Exception from delete_embedding).
      old_ids = all_memories.map { |m| m["id"] }
      placeholders = old_ids.map { "?" }.join(",")

      @db.transaction do
        @db.execute("DELETE FROM memories WHERE id IN (#{placeholders})", old_ids)

        consolidated.each do |mem|
          next unless mem.is_a?(Hash) && mem["content"]
          @memory.store(
            content: mem["content"],
            category: mem["category"],
            source: "consolidated"
          )
        end
      end

      # Clean up embeddings outside the transaction (safe to fail)
      old_ids.each do |id|
        @db.execute("DELETE FROM memory_embeddings WHERE memory_id = ?", [id])
      rescue SQLite3::Exception
        # vec table may not exist — ignore
      end if @db.vec_enabled

      new_count = @memory.count
      log "Memory consolidation complete: #{current_count} → #{new_count} memories"

      @events.append(type: "memories_consolidated", payload: {
        original_count: current_count,
        consolidated_count: new_count,
      })
    rescue StandardError => e
      log "Memory consolidation error: #{e.message}"
      # Never fail over consolidation
    end

    # --- Subtask lifecycle ---

    def check_parent_completion(task)
      parent_id = task["parent_task_id"]
      return unless parent_id

      parent = @tasks.find(parent_id)
      return unless parent

      if @tasks.all_subtasks_completed?(parent_id)
        complete_parent_task(parent)
      end
    end

    # Clear persisted Claude session for a chat.
    # Useful when the user wants a fresh session in REPL/CLI.
    def clear_session!(chat_id)
      return unless chat_id

      @db.execute("DELETE FROM sessions WHERE chat_id = ?", [chat_id])
      @events.append(type: "session_cleared", payload: { chat_id: chat_id })
    end

    # Clear conversation turns, summaries, and session for a chat.
    def clear_context!(chat_id)
      return unless chat_id

      @db.execute("DELETE FROM conversation_turns WHERE chat_id = ?", [chat_id])
      @db.execute("DELETE FROM conversation_summaries WHERE chat_id = ?", [chat_id])
      clear_session!(chat_id)
      @events.append(type: "conversation_cleared", payload: { chat_id: chat_id })
    end

    private

    # --- SDK Streaming ---

    def wire_streaming!
      # Forward streaming text from SDK client to channel for progressive display
      @sdk_client.on_stream do |_task_id, text|
        @channel.stream_text(current_chat_id, text) if @channel.respond_to?(:stream_text)
      end
    end

    # --- Context helpers ---
    # This returns the current chat context for tool callbacks.
    # Since only one task is processed at a time and send_task blocks,
    # we use an instance variable set in process_task.

    def current_chat_id
      @active_chat_id
    end

    # --- Parent task completion ---

    def complete_parent_task(parent_task)
      parent_id = parent_task["id"]
      chat_id   = parent_task["chat_id"]

      subtasks = @tasks.subtasks(parent_id)
      results = subtasks.map { |s| s["result_text"] }.compact.join("\n\n")

      # Transition to completed — handle whatever state the parent is in.
      # The valid paths are: waiting_for_input → running → completed,
      # or running → completed, or blocked → running → completed.
      current_state = @tasks.find(parent_id)["state"]
      case current_state
      when "completed", "failed"
        # Already terminal — nothing to do
        return
      when "waiting_for_input", "blocked"
        @tasks.transition!(parent_id, "running")
        @tasks.transition!(parent_id, "completed", result_text: results)
      when "running"
        @tasks.transition!(parent_id, "completed", result_text: results)
      else
        # Unexpected state (new, scheduled) — try running → completed
        begin
          @tasks.transition!(parent_id, "running")
          @tasks.transition!(parent_id, "completed", result_text: results)
        rescue Task::InvalidTransition => e
          log "Could not complete parent task #{parent_id}: #{e.message}"
          return
        end
      end

      log "Parent task #{parent_id} auto-completed (all #{subtasks.size} subtasks done)"

      if chat_id && !results.empty?
        @channel.send_reply(chat_id, "All steps complete.")
      end
    end

    # --- Task Decomposition ---

    # Check if a task is a candidate for decomposition.
    def should_decompose?(task)
      return false if task["parent_task_id"]  # Never decompose subtasks
      return false unless task["input_text"]
      return false if task["input_text"].length < @config.decomposition_min_length  # Short inputs → direct
      return false if task["source"] == "heartbeat"    # System tasks → direct
      true
    end

    # Ask the SDK if this task should be decomposed. If yes, create subtasks.
    # Returns true if decomposed (caller should not process directly), false otherwise.
    def try_decompose(task)
      result = @sdk_client.send_decompose(task["input_text"], timeout: @config.decompose_timeout)
      return false unless result.is_a?(Hash)
      return false unless result["decompose"] == true

      subtasks = result["subtasks"]
      return false unless subtasks.is_a?(Array) && subtasks.size >= 2

      task_id = task["id"]
      chat_id = task["chat_id"]

      log "Decomposing task #{task_id} into #{subtasks.size} subtasks"

      # Move parent to waiting_for_input
      @tasks.transition!(task_id, "waiting_for_input")

      # Create subtasks
      subtasks.each_with_index do |st, idx|
        sub_id = @tasks.create(
          source: task["source"],
          chat_id: chat_id,
          input_text: st["input"] || st["title"],
          parent_task_id: task_id,
          subtask_index: idx
        )
        log "  Subtask #{idx + 1}: #{st['title']}"
      end

      @events.append(type: "task_decomposed", task_id: task_id, payload: {
        subtask_count: subtasks.size,
        subtask_titles: subtasks.map { |s| s["title"] }
      })

      # Notify the channel
      titles = subtasks.map.with_index { |s, i| "#{i + 1}. #{s['title']}" }.join("\n")
      @channel.send_reply(chat_id, "Breaking this into #{subtasks.size} steps:\n#{titles}") if chat_id

      true
    rescue StandardError => e
      log "Decomposition error: #{e.message}"
      false  # Fall back to direct processing
    end

    # --- Learning Extraction ---

    def extract_learnings(chat_id:, task_id:)
      turns = recent_turns(chat_id: chat_id)
      return if turns.size < 2  # Need at least a user + assistant turn

      conversation_text = turns.map do |t|
        "#{t['role']}: #{t['content']}"
      end.join("\n")

      # Extract lessons (behavioral patterns)
      extract_lessons(conversation_text, task_id: task_id)

      # Extract memories (facts about the user)
      extract_memories(conversation_text, task_id: task_id)
    rescue StandardError => e
      log "Extraction error: #{e.message}"
      # Never fail the main task over extraction
    end

    def extract_lessons(conversation_text, task_id:)
      result = @sdk_client.send_extract(
        conversation_text,
        extract_type: "lessons",
        timeout: @config.extract_timeout
      )
      return unless result.is_a?(Hash)

      lessons = result["lessons"]
      return unless lessons.is_a?(Array)

      lessons.each do |lesson|
        next unless lesson.is_a?(Hash) && lesson["content"]
        @lessons.store(
          content: lesson["content"],
          category: lesson["category"],
          source_task_id: task_id
        )
      end

      log "Extracted #{lessons.size} lessons from task #{task_id}" if lessons.any?
    rescue StandardError => e
      log "Lesson extraction error: #{e.message}"
    end

    def extract_memories(conversation_text, task_id:)
      result = @sdk_client.send_extract(
        conversation_text,
        extract_type: "memories",
        timeout: @config.extract_timeout
      )
      return unless result.is_a?(Hash)

      memories = result["memories"]
      return unless memories.is_a?(Array)

      memories.each do |mem|
        next unless mem.is_a?(Hash) && mem["content"]
        @memory.store(
          content: mem["content"],
          category: mem["category"],
          source: "extracted"
        )
      end

      log "Extracted #{memories.size} memories from task #{task_id}" if memories.any?
    rescue StandardError => e
      log "Memory extraction error: #{e.message}"
    end

    # --- Session Persistence ---

    def load_session(chat_id)
      return nil unless chat_id
      row = @db.get_first_row(
        "SELECT session_id FROM sessions WHERE chat_id = ?", [chat_id]
      )
      row&.dig("session_id")
    end

    def save_session(chat_id, session_id)
      return unless chat_id && session_id
      @db.execute(
        "INSERT INTO sessions (chat_id, session_id, updated_at) VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%f', 'now')) " \
        "ON CONFLICT(chat_id) DO UPDATE SET session_id = excluded.session_id, updated_at = excluded.updated_at",
        [chat_id, session_id]
      )
    end

    # --- Conversation Summarization ---

    # If the turn count for a chat exceeds the threshold, summarize old turns
    # to keep the DB manageable and preserve context for future sessions.
    def maybe_summarize_turns(chat_id)
      return unless chat_id

      threshold = @config.summary_threshold
      keep = @config.max_context_turns

      count = turn_count(chat_id)
      return if count <= threshold

      # Fetch all turns, keep the most recent `keep` turns intact
      all_turns = @db.execute(
        "SELECT * FROM conversation_turns WHERE chat_id = ? ORDER BY id ASC",
        [chat_id]
      )
      return if all_turns.size <= keep

      # Split: old turns to summarize, recent turns to keep
      split_at = all_turns.size - keep
      old_turns = all_turns[0, split_at]
      return if old_turns.nil? || old_turns.empty?

      # Build input: existing summary + old turns
      existing_summary = load_summary(chat_id)
      parts = []
      parts << "Existing summary:\n#{existing_summary}\n" if existing_summary

      old_turns.each do |t|
        parts << "#{t['role']}: #{t['content']}"
      end

      conversation_text = parts.join("\n")

      result = @sdk_client.send_extract(
        conversation_text,
        extract_type: "summary",
        timeout: @config.summary_timeout
      )
      return unless result.is_a?(Hash) && result["summary"]

      save_summary(chat_id, result["summary"], old_turns.size)

      # Delete summarized turns
      max_old_id = old_turns.last["id"]
      @db.execute(
        "DELETE FROM conversation_turns WHERE chat_id = ? AND id <= ?",
        [chat_id, max_old_id]
      )

      log "Summarized #{old_turns.size} turns for chat #{chat_id} (#{count} → #{count - old_turns.size})"
    rescue StandardError => e
      log "Summarization error: #{e.message}"
      # Never fail the main flow over summarization
    end

    def turn_count(chat_id)
      row = @db.get_first_row(
        "SELECT COUNT(*) AS cnt FROM conversation_turns WHERE chat_id = ?",
        [chat_id]
      )
      row ? row["cnt"].to_i : 0
    end

    def load_summary(chat_id)
      return nil unless chat_id
      row = @db.get_first_row(
        "SELECT summary FROM conversation_summaries WHERE chat_id = ?",
        [chat_id]
      )
      row&.dig("summary")
    end

    def save_summary(chat_id, summary, turns_summarized)
      return unless chat_id && summary
      # Load existing count to accumulate
      existing = @db.get_first_row(
        "SELECT turns_summarized FROM conversation_summaries WHERE chat_id = ?",
        [chat_id]
      )
      total = (existing&.dig("turns_summarized") || 0).to_i + turns_summarized

      @db.execute(
        "INSERT INTO conversation_summaries (chat_id, summary, turns_summarized, updated_at) " \
        "VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%f', 'now')) " \
        "ON CONFLICT(chat_id) DO UPDATE SET summary = excluded.summary, " \
        "turns_summarized = excluded.turns_summarized, updated_at = excluded.updated_at",
        [chat_id, summary, total]
      )
    end

    # --- Logging ---

    def log(msg)
      @logger.call(msg)
    end

    def default_log(msg)
      $stdout.puts "[Skein] #{Time.now.utc.iso8601} #{msg}"
    end
  end
end
