require "json"
require "webrick"
require "thread"
require "time"

module Skein
  class ObserverServer
    DEFAULT_HOST = "127.0.0.1"
    DEFAULT_PORT = 4310
    DEFAULT_CHAT_ID = "web"

    def initialize(config: Config.new, host: nil, port: nil, logger: nil)
      @config = config
      @host = host || ENV.fetch("SKEIN_WATCH_HOST", DEFAULT_HOST)
      @port = (port || ENV.fetch("SKEIN_WATCH_PORT", DEFAULT_PORT.to_s)).to_i
      @logger = logger

      @lock = Mutex.new
      @runs = {}
      @active_task_by_chat = {}
      @pending_approvals = {}
      @approval_decisions = {}
      @next_approval_id = 1
      @chat_threads = []
      @chat_runtime_ready = false
    end

    def run
      server = WEBrick::HTTPServer.new(
        BindAddress: @host,
        Port: @port,
        AccessLog: [],
        Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN)
      )

      server.mount_proc("/") { |_req, res| respond_dashboard(res) }
      server.mount_proc("/api/snapshot") { |req, res| respond_snapshot(req, res) }
      server.mount_proc("/api/run_timeline") { |req, res| respond_run_timeline(req, res) }
      server.mount_proc("/api/run_scorecard") { |req, res| respond_run_scorecard(req, res) }
      server.mount_proc("/api/run_diff") { |req, res| respond_run_diff(req, res) }
      server.mount_proc("/api/chat_state") { |req, res| respond_chat_state(req, res) }
      server.mount_proc("/api/chat_send") { |req, res| respond_chat_send(req, res) }
      server.mount_proc("/api/chat_approval") { |req, res| respond_chat_approval(req, res) }

      Signal.trap("INT") { server.shutdown }
      Signal.trap("TERM") { server.shutdown }

      log "Observer UI listening at http://#{@host}:#{@port}"
      server.start
    ensure
      stop_chat_runtime!
    end

    private

    def respond_dashboard(res)
      res.status = 200
      res["Content-Type"] = "text/html; charset=utf-8"
      res.body = dashboard_html
    end

    def respond_snapshot(req, res)
      limit = req.query["limit"].to_i
      limit = 30 if limit <= 0
      limit = 200 if limit > 200

      db = DB.new(@config.db_path, busy_timeout_ms: @config.db_busy_timeout_ms)
      snapshot = build_snapshot(db: db, limit: limit)

      res.status = 200
      res["Content-Type"] = "application/json; charset=utf-8"
      res.body = JSON.generate(snapshot)
    ensure
      db&.close
    end

    def respond_chat_state(req, res)
      chat_id = req.query["chat_id"].to_s
      chat_id = DEFAULT_CHAT_ID if chat_id.empty?

      limit = req.query["limit"].to_i
      limit = 60 if limit <= 0
      limit = 300 if limit > 300

      db = DB.new(@config.db_path, busy_timeout_ms: @config.db_busy_timeout_ms)
      state = build_chat_state(db: db, chat_id: chat_id, limit: limit)

      res.status = 200
      res["Content-Type"] = "application/json; charset=utf-8"
      res.body = JSON.generate(state)
    ensure
      db&.close
    end

    def respond_run_timeline(req, res)
      task_id = req.query["task_id"].to_i
      if task_id <= 0
        res.status = 422
        res["Content-Type"] = "application/json; charset=utf-8"
        res.body = JSON.generate(error: "task_id is required")
        return
      end

      limit = req.query["limit"].to_i
      limit = 300 if limit <= 0
      limit = 1000 if limit > 1000

      db = DB.new(@config.db_path, busy_timeout_ms: @config.db_busy_timeout_ms)
      timeline = build_run_timeline(db: db, task_id: task_id, limit: limit)

      if timeline.nil?
        res.status = 404
        res["Content-Type"] = "application/json; charset=utf-8"
        res.body = JSON.generate(error: "task not found")
        return
      end

      res.status = 200
      res["Content-Type"] = "application/json; charset=utf-8"
      res.body = JSON.generate(timeline)
    ensure
      db&.close
    end

    def respond_run_diff(req, res)
      left_task_id = req.query["left_task_id"].to_i
      right_task_id = req.query["right_task_id"].to_i

      if left_task_id <= 0 || right_task_id <= 0
        res.status = 422
        res["Content-Type"] = "application/json; charset=utf-8"
        res.body = JSON.generate(error: "left_task_id and right_task_id are required")
        return
      end

      db = DB.new(@config.db_path, busy_timeout_ms: @config.db_busy_timeout_ms)
      diff = build_run_diff(db: db, left_task_id: left_task_id, right_task_id: right_task_id)

      if diff.nil?
        res.status = 404
        res["Content-Type"] = "application/json; charset=utf-8"
        res.body = JSON.generate(error: "one or both tasks not found")
        return
      end

      res.status = 200
      res["Content-Type"] = "application/json; charset=utf-8"
      res.body = JSON.generate(diff)
    ensure
      db&.close
    end

    def respond_run_scorecard(req, res)
      task_id = req.query["task_id"].to_i
      if task_id <= 0
        res.status = 422
        res["Content-Type"] = "application/json; charset=utf-8"
        res.body = JSON.generate(error: "task_id is required")
        return
      end

      db = DB.new(@config.db_path, busy_timeout_ms: @config.db_busy_timeout_ms)
      scorecard = build_run_scorecard(db: db, task_id: task_id)

      if scorecard.nil?
        res.status = 404
        res["Content-Type"] = "application/json; charset=utf-8"
        res.body = JSON.generate(error: "task not found")
        return
      end

      res.status = 200
      res["Content-Type"] = "application/json; charset=utf-8"
      res.body = JSON.generate(scorecard)
    ensure
      db&.close
    end

    def respond_chat_send(req, res)
      unless req.request_method == "POST"
        res.status = 405
        res["Content-Type"] = "application/json; charset=utf-8"
        res.body = JSON.generate(error: "Method not allowed")
        return
      end

      payload = parse_json_body(req)
      message = payload["message"].to_s.strip
      chat_id = payload["chat_id"].to_s.strip
      chat_id = DEFAULT_CHAT_ID if chat_id.empty?

      if message.empty?
        res.status = 422
        res["Content-Type"] = "application/json; charset=utf-8"
        res.body = JSON.generate(error: "message is required")
        return
      end

      ensure_chat_runtime!

      active_task = nil
      @lock.synchronize do
        active_task = @active_task_by_chat[chat_id]
      end

      if active_task
        run = nil
        @lock.synchronize { run = @runs[active_task] }
        if run && run[:status] == "running"
          res.status = 409
          res["Content-Type"] = "application/json; charset=utf-8"
          res.body = JSON.generate(error: "chat already has a running task", task_id: active_task)
          return
        end
      end

      task_id = @chat_tasks.create(source: "web", chat_id: chat_id, input_text: message, lane: Lane::L1_INTERACTIVE)
      @chat_tasks.transition!(task_id, "running")

      run = {
        task_id: task_id,
        chat_id: chat_id,
        input: message,
        status: "running",
        stream_text: "",
        final_text: nil,
        error: nil,
        started_at: Time.now.utc.iso8601,
        updated_at: Time.now.utc.iso8601,
      }

      @lock.synchronize do
        @runs[task_id] = run
        @active_task_by_chat[chat_id] = task_id
      end

      thread = Thread.new do
        process_chat_task(task_id)
      end
      @lock.synchronize { @chat_threads << thread }

      res.status = 202
      res["Content-Type"] = "application/json; charset=utf-8"
      res.body = JSON.generate(task_id: task_id, chat_id: chat_id, status: "running")
    rescue JSON::ParserError
      res.status = 400
      res["Content-Type"] = "application/json; charset=utf-8"
      res.body = JSON.generate(error: "invalid JSON body")
    end

    def respond_chat_approval(req, res)
      unless req.request_method == "POST"
        res.status = 405
        res["Content-Type"] = "application/json; charset=utf-8"
        res.body = JSON.generate(error: "Method not allowed")
        return
      end

      payload = parse_json_body(req)
      approval_id = payload["approval_id"].to_i
      decision = payload["decision"].to_s

      unless approval_id.positive? && %w[allow deny].include?(decision)
        res.status = 422
        res["Content-Type"] = "application/json; charset=utf-8"
        res.body = JSON.generate(error: "approval_id and decision (allow|deny) are required")
        return
      end

      exists = false
      @lock.synchronize do
        exists = @pending_approvals.key?(approval_id)
        @approval_decisions[approval_id] = decision if exists
      end

      unless exists
        res.status = 404
        res["Content-Type"] = "application/json; charset=utf-8"
        res.body = JSON.generate(error: "approval not found")
        return
      end

      res.status = 200
      res["Content-Type"] = "application/json; charset=utf-8"
      res.body = JSON.generate(ok: true, approval_id: approval_id, decision: decision)
    rescue JSON::ParserError
      res.status = 400
      res["Content-Type"] = "application/json; charset=utf-8"
      res.body = JSON.generate(error: "invalid JSON body")
    end

    def build_snapshot(db:, limit:)
      task_rows = db.execute(
        "SELECT id, state, lane, source, chat_id, input_text, result_text, error_message, created_at, updated_at " \
        "FROM tasks ORDER BY id DESC LIMIT ?",
        [limit]
      )

      event_rows = db.execute(
        "SELECT id, type, task_id, payload, created_at FROM events ORDER BY id DESC LIMIT ?",
        [limit]
      ).map { |row| parse_event_row(row) }

      turn_rows = db.execute(
        "SELECT id, chat_id, role, content, task_id, created_at FROM conversation_turns ORDER BY id DESC LIMIT ?",
        [limit]
      )

      memory_rows = db.execute(
        "SELECT id, content, category, source, access_count, created_at " \
        "FROM memories ORDER BY access_count DESC, created_at DESC LIMIT ?",
        [limit]
      )

      lesson_rows = db.execute(
        "SELECT id, content, category, effectiveness, applied_count, created_at " \
        "FROM lessons ORDER BY effectiveness DESC, applied_count DESC, created_at DESC LIMIT ?",
        [limit]
      )

      states = db.execute("SELECT state, COUNT(*) AS cnt FROM tasks GROUP BY state")
      state_counts = states.each_with_object({}) { |row, h| h[row["state"]] = row["cnt"].to_i }

      {
        generated_at: Time.now.utc.iso8601,
        db_path: @config.db_path,
        counts: {
          tasks: scalar_count(db, "tasks"),
          events: scalar_count(db, "events"),
          memories: scalar_count(db, "memories"),
          lessons: scalar_count(db, "lessons"),
          timers: scalar_count(db, "timers"),
          turns: scalar_count(db, "conversation_turns"),
          sessions: scalar_count(db, "sessions"),
        },
        task_state_counts: state_counts,
        recent_tasks: task_rows,
        recent_events: event_rows,
        recent_turns: turn_rows,
        recent_memories: memory_rows,
        recent_lessons: lesson_rows,
      }
    end

    def build_chat_state(db:, chat_id:, limit:)
      turns = db.execute(
        "SELECT id, chat_id, role, content, task_id, created_at " \
        "FROM conversation_turns WHERE chat_id = ? ORDER BY id DESC LIMIT ?",
        [chat_id, limit]
      ).reverse

      active_run = nil
      pending = []
      recent_runs = []
      @lock.synchronize do
        task_id = @active_task_by_chat[chat_id]
        active_run = @runs[task_id]&.dup if task_id
        pending = @pending_approvals.values
                                   .select { |a| a[:chat_id] == chat_id }
                                   .map(&:dup)
                                   .sort_by { |a| a[:id] }
        recent_runs = @runs.values
                           .select { |r| r[:chat_id] == chat_id }
                           .sort_by { |r| -r[:task_id].to_i }
                           .first(15)
                           .map(&:dup)
      end

      {
        chat_id: chat_id,
        turns: turns,
        active_run: active_run,
        recent_runs: recent_runs,
        pending_approvals: pending,
      }
    end

    def build_run_timeline(db:, task_id:, limit:)
      task = db.get_first_row(
        "SELECT id, state, lane, source, chat_id, input_text, result_text, error_message, created_at, updated_at " \
        "FROM tasks WHERE id = ?",
        [task_id]
      )
      return nil unless task

      events = db.execute(
        "SELECT id, type, task_id, payload, created_at FROM events WHERE task_id = ? ORDER BY id ASC LIMIT ?",
        [task_id, limit]
      ).map { |row| parse_event_row(row) }

      turns = db.execute(
        "SELECT id, role, content, created_at FROM conversation_turns WHERE task_id = ? ORDER BY id ASC LIMIT ?",
        [task_id, limit]
      )

      steps = []
      steps << {
        kind: "task",
        label: "Task created",
        at: task["created_at"],
        detail: {
          state: task["state"],
          source: task["source"],
          lane: task["lane"],
          chat_id: task["chat_id"],
          input_text: task["input_text"],
        },
      }

      events.each do |event|
        steps << {
          kind: "event",
          label: event["type"],
          at: event["created_at"],
          detail: event["payload"],
        }
      end

      turns.each do |turn|
        steps << {
          kind: "turn",
          label: "#{turn['role']} message",
          at: turn["created_at"],
          detail: {
            role: turn["role"],
            content: turn["content"],
          },
        }
      end

      steps.sort_by! { |s| s[:at].to_s }

      {
        task: task,
        steps: steps,
      }
    end

    def build_run_diff(db:, left_task_id:, right_task_id:)
      left = build_run_snapshot(db: db, task_id: left_task_id)
      right = build_run_snapshot(db: db, task_id: right_task_id)
      return nil unless left && right

      changed_fields = %w[state lane source chat_id].select do |field|
        left[:task][field] != right[:task][field]
      end

      all_event_types = (left[:event_counts].keys + right[:event_counts].keys).uniq.sort
      event_count_delta = all_event_types.to_h do |type|
        [type, right[:event_counts].fetch(type, 0) - left[:event_counts].fetch(type, 0)]
      end

      {
        left: left,
        right: right,
        diff: {
          changed_fields: changed_fields,
          metric_delta: {
            duration_seconds: right[:metrics][:duration_seconds] - left[:metrics][:duration_seconds],
            input_length: right[:metrics][:input_length] - left[:metrics][:input_length],
            output_length: right[:metrics][:output_length] - left[:metrics][:output_length],
            event_count: right[:metrics][:event_count] - left[:metrics][:event_count],
            turn_count: right[:metrics][:turn_count] - left[:metrics][:turn_count],
          },
          event_count_delta: event_count_delta,
        },
      }
    end

    def build_run_scorecard(db:, task_id:)
      snapshot = build_run_snapshot(db: db, task_id: task_id)
      return nil unless snapshot

      task = snapshot[:task]
      metrics = snapshot[:metrics]
      event_counts = snapshot[:event_counts]

      score = 100
      notes = []

      case task["state"]
      when "completed"
        notes << "Task completed"
      when "failed"
        score -= 45
        notes << "Task failed"
      else
        score -= 20
        notes << "Task not completed (#{task['state']})"
      end

      if event_counts["error_occurred"].to_i.positive?
        score -= 20
        notes << "#{event_counts['error_occurred']} error event(s) recorded"
      end

      unless task["error_message"].to_s.strip.empty?
        score -= 15
        notes << "Task contains error message"
      end

      duration = metrics[:duration_seconds].to_f
      if duration > 60
        score -= 15
        notes << "Long runtime (> 60s)"
      elsif duration > 30
        score -= 8
        notes << "Slow runtime (> 30s)"
      end

      score += 5 if event_counts["task_decomposed"].to_i.positive?
      score += 3 if event_counts["sdk_response_received"].to_i.positive?

      score = [[score, 100].min, 0].max
      grade = if score >= 90
        "A"
      elsif score >= 75
        "B"
      elsif score >= 60
        "C"
      elsif score >= 40
        "D"
      else
        "F"
      end

      {
        task_id: task["id"],
        state: task["state"],
        score: score,
        grade: grade,
        metrics: {
          duration_seconds: duration,
          event_count: metrics[:event_count],
          turn_count: metrics[:turn_count],
          input_length: metrics[:input_length],
          output_length: metrics[:output_length],
          error_events: event_counts["error_occurred"].to_i,
        },
        notes: notes,
      }
    end

    def build_run_snapshot(db:, task_id:)
      task = db.get_first_row(
        "SELECT id, state, lane, source, chat_id, input_text, result_text, error_message, created_at, updated_at " \
        "FROM tasks WHERE id = ?",
        [task_id]
      )
      return nil unless task

      event_rows = db.execute(
        "SELECT type FROM events WHERE task_id = ?",
        [task_id]
      )
      event_counts = event_rows.each_with_object(Hash.new(0)) { |row, h| h[row["type"]] += 1 }

      turns = db.execute(
        "SELECT role, content FROM conversation_turns WHERE task_id = ? ORDER BY id ASC",
        [task_id]
      )

      duration_seconds = time_diff_seconds(task["created_at"], task["updated_at"])

      {
        task: task,
        metrics: {
          duration_seconds: duration_seconds,
          input_length: task["input_text"].to_s.length,
          output_length: task["result_text"].to_s.length,
          event_count: event_rows.size,
          turn_count: turns.size,
        },
        event_counts: event_counts,
        previews: {
          input_text: task["input_text"].to_s[0, 500],
          result_text: task["result_text"].to_s[0, 500],
          error_message: task["error_message"].to_s[0, 500],
          last_turn: turns.last && { "role" => turns.last["role"], "content" => turns.last["content"].to_s[0, 300] },
        },
      }
    end

    def time_diff_seconds(start_at, end_at)
      return 0.0 if start_at.nil? || end_at.nil?

      start_t = Time.parse(start_at)
      end_t = Time.parse(end_at)
      diff = end_t - start_t
      diff.negative? ? 0.0 : diff.round(3)
    rescue ArgumentError
      0.0
    end

    def scalar_count(db, table)
      row = db.get_first_row("SELECT COUNT(*) AS cnt FROM #{table}")
      row["cnt"].to_i
    end

    def parse_event_row(row)
      payload = begin
        JSON.parse(row["payload"])
      rescue JSON::ParserError
        row["payload"]
      end

      row.merge("payload" => payload)
    end

    def parse_json_body(req)
      raw = req.body.to_s
      return {} if raw.empty?

      JSON.parse(raw)
    end

    def ensure_chat_runtime!
      return if @chat_runtime_ready

      @chat_db = DB.new(@config.db_path, busy_timeout_ms: @config.db_busy_timeout_ms)
      @chat_events = EventStore.new(@chat_db)
      @chat_tasks = Task.new(db: @chat_db, event_store: @chat_events)
      @chat_timers = Timer.new(db: @chat_db, event_store: @chat_events)
      embedder = nil
      if @config.embedding_enabled
        begin
          embedder = Embedder.new(model_name: @config.embedding_model)
        rescue LoadError => e
          log "Embeddings disabled for observer chat: #{e.message}"
        end
      end
      @chat_memory = Memory.new(db: @chat_db, event_store: @chat_events, embedder: embedder)
      @chat_lessons = Lesson.new(db: @chat_db, event_store: @chat_events)

      tool_executor = ToolExecutor.new(memory: @chat_memory, timers: @chat_timers, config: @config)
      skill_registry = SkillRegistry.new(
        context: {
          memory: @chat_memory,
          timers: @chat_timers,
          lessons: @chat_lessons,
          events: @chat_events,
          db: @chat_db,
          config: @config,
          logger: method(:log),
        },
        logger: method(:log)
      )
      skill_registry.load_all!
      skill_registry.register_tools!(tool_executor)

      sdk_client = SdkClient.new(config: @config, tool_executor: tool_executor, channel: self, logger: method(:log))

      @chat_agent = Agent.new(
        config: @config,
        db: @chat_db,
        events: @chat_events,
        tasks: @chat_tasks,
        timers: @chat_timers,
        memory: @chat_memory,
        lessons: @chat_lessons,
        sdk_client: sdk_client,
        tool_executor: tool_executor,
        skill_registry: skill_registry,
        channel: self,
        logger: method(:log)
      )

      @chat_agent.start_sdk
      @chat_agent.recover_stale_tasks!
      @chat_runtime_ready = true
      log "Observer chat runtime initialized"
    end

    def stop_chat_runtime!
      return unless @chat_runtime_ready

      @chat_threads.each(&:join)
      @chat_agent&.stop_sdk
      @chat_db&.close
      @chat_runtime_ready = false
    rescue StandardError => e
      log "Observer chat shutdown error: #{e.message}"
    end

    def process_chat_task(task_id)
      task = @chat_tasks.find(task_id)
      return unless task

      @chat_agent.process_task(task)
      final = @chat_tasks.find(task_id)
      @lock.synchronize do
        run = @runs[task_id]
        if run
          run[:status] = final ? final["state"] : "completed"
          run[:final_text] = final ? final["result_text"] : run[:final_text]
          run[:error] = final ? final["error_message"] : run[:error]
          run[:updated_at] = Time.now.utc.iso8601
        end
        @active_task_by_chat.delete(run[:chat_id]) if run
      end
    rescue StandardError => e
      @lock.synchronize do
        run = @runs[task_id]
        if run
          run[:status] = "failed"
          run[:error] = e.message
          run[:updated_at] = Time.now.utc.iso8601
          @active_task_by_chat.delete(run[:chat_id])
        end
      end
      log "Observer chat task #{task_id} failed: #{e.message}"
    end

    public

    # --- Agent channel adapter for browser chat ---

    def stream_text(chat_id, text)
      update_active_run(chat_id) do |run|
        run[:stream_text] = "" unless run[:stream_text]
        run[:stream_text] << text.to_s
      end
    end

    def stream_end(chat_id)
      update_active_run(chat_id) do |run|
        run[:stream_done] = true
      end
    end

    def send_reply(chat_id, text)
      update_active_run(chat_id) do |run|
        run[:final_text] = text.to_s
      end
    end

    def request_approval(chat_id, tool_name, tool_input)
      approval_id = nil
      @lock.synchronize do
        approval_id = @next_approval_id
        @next_approval_id += 1
        @pending_approvals[approval_id] = {
          id: approval_id,
          chat_id: chat_id,
          task_id: @active_task_by_chat[chat_id],
          tool_name: tool_name,
          tool_input: tool_input,
          created_at: Time.now.utc.iso8601,
        }
      end

      deadline = Time.now + @config.approval_timeout
      loop do
        decision = nil
        @lock.synchronize do
          decision = @approval_decisions.delete(approval_id)
        end

        if decision
          @lock.synchronize { @pending_approvals.delete(approval_id) }
          return decision
        end

        break if Time.now > deadline

        sleep 0.1
      end

      @lock.synchronize { @pending_approvals.delete(approval_id) }
      "deny"
    end

    def update_active_run(chat_id)
      @lock.synchronize do
        task_id = @active_task_by_chat[chat_id]
        run = @runs[task_id]
        return unless run

        yield run
        run[:updated_at] = Time.now.utc.iso8601
      end
    end

    private

    def log(message)
      if @logger
        @logger.call(message)
      else
        $stdout.puts "[Skein::Observer] #{Time.now.utc.iso8601} #{message}"
      end
    end

    def dashboard_html
      <<~HTML
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <title>Skein Observer</title>
          <style>
            :root {
              --bg: #f4f1ea;
              --panel: #fffdf7;
              --ink: #1f2937;
              --muted: #6b7280;
              --accent: #0f766e;
              --border: #e5e7eb;
            }
            body { margin: 0; font-family: "IBM Plex Sans", "Segoe UI", sans-serif; background: radial-gradient(circle at top, #fffaf0, var(--bg)); color: var(--ink); }
            header { padding: 18px 22px; border-bottom: 1px solid var(--border); background: rgba(255,253,247,0.8); backdrop-filter: blur(4px); position: sticky; top: 0; }
            h1 { margin: 0; font-size: 20px; }
            .muted { color: var(--muted); font-size: 12px; }
            .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 10px; margin-top: 10px; }
            .card { background: var(--panel); border: 1px solid var(--border); border-radius: 10px; padding: 10px 12px; }
            .card h3 { margin: 0 0 5px 0; font-size: 12px; color: var(--muted); text-transform: uppercase; letter-spacing: .06em; }
            .card .value { font-size: 22px; font-weight: 700; color: var(--accent); }
            .chat-shell { margin: 14px 22px 0; background: var(--panel); border: 1px solid var(--border); border-radius: 12px; overflow: hidden; }
            .chat-header { margin: 0; padding: 10px 12px; font-size: 14px; border-bottom: 1px solid var(--border); background: #faf7ef; display: flex; justify-content: space-between; align-items: center; }
            .chat-messages { max-height: 280px; overflow: auto; padding: 10px 12px; display: grid; gap: 8px; background: #fffefb; }
            .bubble { border: 1px solid var(--border); border-radius: 10px; padding: 8px 10px; font-size: 13px; line-height: 1.35; white-space: pre-wrap; }
            .bubble.user { background: #f0fdfa; border-color: #b8ece6; }
            .bubble.assistant { background: #f9f8f4; }
            .bubble.system { background: #fff3e8; border-color: #f3d2b4; }
            .bubble .meta { display: block; font-size: 11px; color: var(--muted); margin-bottom: 4px; }
            .chat-controls { display: grid; grid-template-columns: 1fr auto; gap: 8px; padding: 10px 12px; border-top: 1px solid var(--border); background: #fffdf7; }
            .chat-controls textarea { width: 100%; min-height: 56px; resize: vertical; border: 1px solid var(--border); border-radius: 8px; padding: 8px; font: inherit; }
            .chat-controls button { border: 0; border-radius: 8px; padding: 0 16px; background: var(--accent); color: white; font-weight: 600; cursor: pointer; }
            .chat-controls button:disabled { opacity: 0.5; cursor: not-allowed; }
            .approvals { border-top: 1px solid var(--border); padding: 8px 12px; display: grid; gap: 8px; background: #fff8ef; }
            .approval { border: 1px solid #f2dcc1; border-radius: 8px; padding: 8px; }
            .approval-actions { margin-top: 6px; display: flex; gap: 6px; }
            .approval-actions button { border: 0; border-radius: 6px; padding: 4px 8px; cursor: pointer; }
            .approval-actions .allow { background: #0f766e; color: white; }
            .approval-actions .deny { background: #b91c1c; color: white; }
            .timeline-controls { display: grid; grid-template-columns: auto 1fr auto; gap: 8px; padding: 8px 12px; border-bottom: 1px solid var(--border); background: #faf7ef; align-items: center; }
            .timeline-controls input { border: 1px solid var(--border); border-radius: 6px; padding: 6px 8px; font: inherit; }
            .timeline-controls button { border: 0; border-radius: 6px; padding: 6px 10px; background: var(--accent); color: white; cursor: pointer; }
            .timeline-step { border-bottom: 1px solid #f0eee8; padding: 8px 10px; }
            .timeline-step:last-child { border-bottom: 0; }
            .timeline-step .label { font-weight: 600; }
            .timeline-step .detail { margin-top: 4px; font-size: 12px; color: var(--muted); white-space: pre-wrap; }
            .scorecard { border-bottom: 1px solid var(--border); padding: 8px 10px; background: #fffefb; }
            .scorecard .grade { font-size: 20px; font-weight: 700; color: var(--accent); }
            .scorecard .notes { margin-top: 6px; font-size: 12px; color: var(--muted); }
            .diff-controls { display: grid; grid-template-columns: auto 1fr auto 1fr auto; gap: 8px; padding: 8px 12px; border-bottom: 1px solid var(--border); background: #faf7ef; align-items: center; }
            .diff-controls input { border: 1px solid var(--border); border-radius: 6px; padding: 6px 8px; font: inherit; }
            .diff-controls button { border: 0; border-radius: 6px; padding: 6px 10px; background: var(--accent); color: white; cursor: pointer; }
            .diff-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; padding: 10px; }
            .diff-card { border: 1px solid var(--border); border-radius: 10px; background: #fffefb; padding: 8px; }
            .diff-card h3 { margin: 0 0 6px 0; font-size: 13px; }
            .diff-row { display: flex; justify-content: space-between; gap: 6px; border-bottom: 1px solid #f4f1eb; padding: 4px 0; font-size: 12px; }
            .diff-row:last-child { border-bottom: 0; }
            .diff-delta { padding: 0 10px 10px; }
            .diff-delta table { width: 100%; border-collapse: collapse; }
            .diff-delta th, .diff-delta td { text-align: left; font-size: 12px; padding: 4px 6px; border-bottom: 1px solid #f4f1eb; }
            .delta-pos { color: #0f766e; font-weight: 600; }
            .delta-neg { color: #b91c1c; font-weight: 600; }
            main { padding: 18px 22px 30px; display: grid; grid-template-columns: repeat(auto-fit, minmax(420px, 1fr)); gap: 14px; }
            section { background: var(--panel); border: 1px solid var(--border); border-radius: 12px; overflow: hidden; }
            section h2 { margin: 0; padding: 10px 12px; font-size: 14px; border-bottom: 1px solid var(--border); background: #faf7ef; }
            table { width: 100%; border-collapse: collapse; }
            th, td { text-align: left; font-size: 12px; padding: 6px 8px; border-bottom: 1px solid #f0eee8; vertical-align: top; }
            th { color: var(--muted); font-weight: 600; }
            .mono { font-family: ui-monospace, Menlo, monospace; }
            .scroll { max-height: 42vh; overflow: auto; }
            @media (max-width: 980px) {
              main { grid-template-columns: 1fr; }
              .diff-controls { grid-template-columns: 1fr; }
              .diff-grid { grid-template-columns: 1fr; }
            }
          </style>
        </head>
        <body>
          <header>
            <h1>Skein Observer</h1>
            <div id="meta" class="muted">Loading...</div>
            <div class="grid" id="counts"></div>
          </header>
          <section class="chat-shell">
            <h2 class="chat-header">
              <span>Browser Chat</span>
              <span id="chatStatus" class="muted">Ready</span>
            </h2>
            <div id="chatMessages" class="chat-messages"></div>
            <div id="chatApprovals" class="approvals" style="display:none"></div>
            <div class="chat-controls">
              <textarea id="chatInput" placeholder="Send a message to Skein (Ctrl/Cmd+Enter to send)"></textarea>
              <button id="chatSend">Send</button>
            </div>
          </section>
          <main>
            <section>
              <h2>Recent Tasks</h2>
              <div class="scroll"><table><thead><tr><th>ID</th><th>State</th><th>Input</th><th>Updated</th></tr></thead><tbody id="tasks"></tbody></table></div>
            </section>
            <section>
              <h2>Recent Events</h2>
              <div class="scroll"><table><thead><tr><th>ID</th><th>Type</th><th>Task</th><th>Payload</th></tr></thead><tbody id="events"></tbody></table></div>
            </section>
            <section>
              <h2>Task State Counts</h2>
              <div class="scroll"><table><thead><tr><th>State</th><th>Count</th></tr></thead><tbody id="stateCounts"></tbody></table></div>
            </section>
            <section>
              <h2>Recent Turns</h2>
              <div class="scroll"><table><thead><tr><th>ID</th><th>Chat</th><th>Role</th><th>Content</th></tr></thead><tbody id="turns"></tbody></table></div>
            </section>
            <section>
              <h2>Memories</h2>
              <div class="scroll"><table><thead><tr><th>ID</th><th>Content</th><th>Category</th><th>Access</th></tr></thead><tbody id="memories"></tbody></table></div>
            </section>
            <section>
              <h2>Lessons</h2>
              <div class="scroll"><table><thead><tr><th>ID</th><th>Content</th><th>Category</th><th>Score</th><th>Uses</th></tr></thead><tbody id="lessons"></tbody></table></div>
            </section>
            <section>
              <h2>Run Timeline Replay</h2>
              <div class="timeline-controls">
                <span class="muted">Task ID</span>
                <input id="timelineTaskId" type="number" min="1" placeholder="Select from tasks or type id" />
                <button id="timelineLoad">Load</button>
              </div>
              <div id="timelineScorecard" class="scorecard" style="display:none"></div>
              <div id="timelineSteps" class="scroll"></div>
            </section>
            <section>
              <h2>Run Diff Mode</h2>
              <div class="diff-controls">
                <span class="muted">Left</span>
                <input id="diffLeftTaskId" type="number" min="1" placeholder="Task id" />
                <span class="muted">Right</span>
                <input id="diffRightTaskId" type="number" min="1" placeholder="Task id" />
                <button id="diffLoad">Compare</button>
              </div>
              <div id="diffResult" class="scroll"></div>
            </section>
          </main>
          <script>
            const countsEl = document.getElementById("counts")
            const metaEl = document.getElementById("meta")
            const tasksEl = document.getElementById("tasks")
            const eventsEl = document.getElementById("events")
            const turnsEl = document.getElementById("turns")
            const stateCountsEl = document.getElementById("stateCounts")
            const memoriesEl = document.getElementById("memories")
            const lessonsEl = document.getElementById("lessons")
            const chatMessagesEl = document.getElementById("chatMessages")
            const chatInputEl = document.getElementById("chatInput")
            const chatSendEl = document.getElementById("chatSend")
            const chatStatusEl = document.getElementById("chatStatus")
            const chatApprovalsEl = document.getElementById("chatApprovals")
            const chatId = "web"
            const timelineTaskIdEl = document.getElementById("timelineTaskId")
            const timelineLoadEl = document.getElementById("timelineLoad")
            const timelineStepsEl = document.getElementById("timelineSteps")
            const timelineScorecardEl = document.getElementById("timelineScorecard")
            const diffLeftTaskIdEl = document.getElementById("diffLeftTaskId")
            const diffRightTaskIdEl = document.getElementById("diffRightTaskId")
            const diffLoadEl = document.getElementById("diffLoad")
            const diffResultEl = document.getElementById("diffResult")

            function escapeHtml(v) {
              return String(v ?? "")
                .replaceAll("&", "&amp;")
                .replaceAll("<", "&lt;")
                .replaceAll(">", "&gt;")
            }

            function truncate(v, n = 90) {
              const s = String(v ?? "")
              return s.length > n ? s.slice(0, n - 3) + "..." : s
            }

            function renderCounts(counts) {
              countsEl.innerHTML = Object.entries(counts).map(([k,v]) =>
                `<div class="card"><h3>${escapeHtml(k)}</h3><div class="value">${escapeHtml(v)}</div></div>`
              ).join("")
            }

            function renderTasks(rows) {
              tasksEl.innerHTML = rows.map(t => {
                const input = truncate(t.input_text || "(no input)")
                return `<tr>
                  <td class="mono">${escapeHtml(t.id)}</td>
                  <td>${escapeHtml(t.state)}</td>
                  <td>${escapeHtml(input)}</td>
                  <td class="mono">${escapeHtml(t.updated_at || "")}</td>
                </tr>`
              }).join("")

              tasksEl.querySelectorAll("tr").forEach((row, idx) => {
                const task = rows[idx]
                if (!task) return
                row.style.cursor = "pointer"
                row.title = "Click: timeline + set left diff ID. Shift+Click: set right diff ID."
                row.addEventListener("click", (evt) => {
                  timelineTaskIdEl.value = task.id
                  loadTimeline(task.id)

                  if (evt.shiftKey) {
                    diffRightTaskIdEl.value = task.id
                  } else {
                    diffLeftTaskIdEl.value = task.id
                  }
                })
              })
            }

            function renderEvents(rows) {
              eventsEl.innerHTML = rows.map(e => {
                let payload = ""
                try {
                  payload = truncate(JSON.stringify(e.payload))
                } catch (_err) {
                  payload = truncate(String(e.payload || ""))
                }
                return `<tr>
                  <td class="mono">${escapeHtml(e.id)}</td>
                  <td>${escapeHtml(e.type)}</td>
                  <td class="mono">${escapeHtml(e.task_id || "")}</td>
                  <td class="mono">${escapeHtml(payload)}</td>
                </tr>`
              }).join("")
            }

            function renderTurns(rows) {
              turnsEl.innerHTML = rows.map(t => `
                <tr>
                  <td class="mono">${escapeHtml(t.id)}</td>
                  <td class="mono">${escapeHtml(t.chat_id)}</td>
                  <td>${escapeHtml(t.role)}</td>
                  <td>${escapeHtml(truncate(t.content, 100))}</td>
                </tr>
              `).join("")
            }

            function renderStateCounts(rows) {
              const entries = Object.entries(rows || {}).sort((a,b) => b[1] - a[1])
              stateCountsEl.innerHTML = entries.map(([state, count]) => `
                <tr>
                  <td>${escapeHtml(state)}</td>
                  <td class="mono">${escapeHtml(count)}</td>
                </tr>
              `).join("")
            }

            function renderMemories(rows) {
              memoriesEl.innerHTML = rows.map(m => `
                <tr>
                  <td class="mono">${escapeHtml(m.id)}</td>
                  <td>${escapeHtml(truncate(m.content, 110))}</td>
                  <td>${escapeHtml(m.category || "")}</td>
                  <td class="mono">${escapeHtml(m.access_count ?? 0)}</td>
                </tr>
              `).join("")
            }

            function renderLessons(rows) {
              lessonsEl.innerHTML = rows.map(l => `
                <tr>
                  <td class="mono">${escapeHtml(l.id)}</td>
                  <td>${escapeHtml(truncate(l.content, 110))}</td>
                  <td>${escapeHtml(l.category || "")}</td>
                  <td class="mono">${escapeHtml(l.effectiveness ?? 0)}</td>
                  <td class="mono">${escapeHtml(l.applied_count ?? 0)}</td>
                </tr>
              `).join("")
            }

            function renderChat(turns, activeRun, recentRuns) {
              const bubbles = []

              ;(turns || []).forEach(t => {
                bubbles.push(`
                  <div class="bubble ${escapeHtml(t.role)}">
                    <span class="meta">${escapeHtml(t.role)} #${escapeHtml(t.id)} ${escapeHtml(t.created_at || "")}</span>
                    ${escapeHtml(t.content || "")}
                  </div>
                `)
              })

              if (activeRun && activeRun.stream_text) {
                bubbles.push(`
                  <div class="bubble assistant">
                    <span class="meta">assistant (streaming) task #${escapeHtml(activeRun.task_id)}</span>
                    ${escapeHtml(activeRun.stream_text)}
                  </div>
                `)
              }

              if (!bubbles.length) {
                bubbles.push(`<div class="muted">No chat yet. Send a message above.</div>`)
              }

              chatMessagesEl.innerHTML = bubbles.join("")
              chatMessagesEl.scrollTop = chatMessagesEl.scrollHeight

              const busy = activeRun && activeRun.status === "running"
              chatSendEl.disabled = !!busy
              if (busy) {
                chatStatusEl.textContent = `Running task #${activeRun.task_id}...`
              } else if (activeRun && activeRun.status === "failed") {
                chatStatusEl.textContent = `Last task failed: ${activeRun.error || "unknown error"}`
              } else if ((recentRuns || []).length > 0) {
                chatStatusEl.textContent = `Last task #${recentRuns[0].task_id}: ${recentRuns[0].status}`
              } else {
                chatStatusEl.textContent = "Ready"
              }
            }

            function renderApprovals(rows) {
              if (!rows || rows.length === 0) {
                chatApprovalsEl.style.display = "none"
                chatApprovalsEl.innerHTML = ""
                return
              }

              chatApprovalsEl.style.display = "grid"
              chatApprovalsEl.innerHTML = rows.map(a => {
                let input = ""
                try {
                  input = truncate(JSON.stringify(a.tool_input), 180)
                } catch (_err) {
                  input = truncate(String(a.tool_input || ""), 180)
                }
                return `
                  <div class="approval">
                    <div><strong>${escapeHtml(a.tool_name)}</strong> (task #${escapeHtml(a.task_id || "")})</div>
                    <div class="mono muted">${escapeHtml(input)}</div>
                    <div class="approval-actions">
                      <button class="allow" data-approval-id="${escapeHtml(a.id)}" data-decision="allow">Approve</button>
                      <button class="deny" data-approval-id="${escapeHtml(a.id)}" data-decision="deny">Deny</button>
                    </div>
                  </div>
                `
              }).join("")

              chatApprovalsEl.querySelectorAll("button[data-approval-id]").forEach(btn => {
                btn.addEventListener("click", async () => {
                  const approvalId = Number(btn.getAttribute("data-approval-id"))
                  const decision = btn.getAttribute("data-decision")
                  await submitApproval(approvalId, decision)
                })
              })
            }

            async function submitApproval(approvalId, decision) {
              await fetch("/api/chat_approval", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ approval_id: approvalId, decision })
              })
            }

            async function sendChat() {
              const message = chatInputEl.value.trim()
              if (!message) return

              chatSendEl.disabled = true
              try {
                const res = await fetch("/api/chat_send", {
                  method: "POST",
                  headers: { "Content-Type": "application/json" },
                  body: JSON.stringify({ chat_id: chatId, message })
                })
                if (!res.ok) {
                  const body = await res.json().catch(() => ({}))
                  throw new Error(body.error || `HTTP ${res.status}`)
                }
                chatInputEl.value = ""
              } catch (err) {
                chatStatusEl.textContent = `Chat send error: ${err.message}`
              }
            }

            async function loadTimeline(taskId) {
              const id = Number(taskId || timelineTaskIdEl.value)
              if (!id || id <= 0) return

              timelineStepsEl.innerHTML = `<div class="timeline-step muted">Loading timeline for task #${id}...</div>`
              timelineScorecardEl.style.display = "none"
              try {
                const [timelineRes, scoreRes] = await Promise.all([
                  fetch(`/api/run_timeline?task_id=${id}&limit=400`),
                  fetch(`/api/run_scorecard?task_id=${id}`)
                ])

                if (!timelineRes.ok) {
                  const body = await timelineRes.json().catch(() => ({}))
                  throw new Error(body.error || `HTTP ${timelineRes.status}`)
                }

                const timelineData = await timelineRes.json()
                renderTimeline(timelineData)

                if (scoreRes.ok) {
                  const scoreData = await scoreRes.json()
                  renderScorecard(scoreData)
                }
              } catch (err) {
                timelineStepsEl.innerHTML = `<div class="timeline-step muted">Timeline error: ${escapeHtml(err.message)}</div>`
                timelineScorecardEl.style.display = "none"
              }
            }

            function renderTimeline(data) {
              const steps = data.steps || []
              if (steps.length === 0) {
                timelineStepsEl.innerHTML = `<div class="timeline-step muted">No timeline data for this task.</div>`
                return
              }

              timelineStepsEl.innerHTML = steps.map(step => {
                let detail = ""
                try {
                  detail = JSON.stringify(step.detail || {}, null, 2)
                } catch (_err) {
                  detail = String(step.detail || "")
                }

                return `
                  <div class="timeline-step">
                    <div class="label">${escapeHtml(step.label || step.kind)} <span class="muted">(${escapeHtml(step.at || "")})</span></div>
                    <div class="detail mono">${escapeHtml(detail)}</div>
                  </div>
                `
              }).join("")
            }

            function renderScorecard(scorecard) {
              const notes = (scorecard.notes || []).map(n => `<li>${escapeHtml(n)}</li>`).join("")
              timelineScorecardEl.style.display = "block"
              timelineScorecardEl.innerHTML = `
                <div><span class="muted">Outcome score</span> <span class="grade">${escapeHtml(scorecard.grade)} (${escapeHtml(scorecard.score)})</span></div>
                <div class="muted">state: ${escapeHtml(scorecard.state)} | duration: ${escapeHtml(scorecard.metrics.duration_seconds)}s | events: ${escapeHtml(scorecard.metrics.event_count)} | turns: ${escapeHtml(scorecard.metrics.turn_count)}</div>
                <ul class="notes">${notes}</ul>
              `
            }

            function renderRunDiff(data) {
              const left = data.left || {}
              const right = data.right || {}
              const diff = data.diff || {}
              const changed = (diff.changed_fields || []).join(", ") || "none"

              const leftTask = left.task || {}
              const rightTask = right.task || {}
              const leftMetrics = left.metrics || {}
              const rightMetrics = right.metrics || {}
              const metricDelta = diff.metric_delta || {}
              const eventDelta = diff.event_count_delta || {}

              function row(label, a, b) {
                return `<div class="diff-row"><span>${escapeHtml(label)}</span><span class="mono">${escapeHtml(a)} → ${escapeHtml(b)}</span></div>`
              }

              function deltaClass(v) {
                if (v > 0) return "delta-pos"
                if (v < 0) return "delta-neg"
                return ""
              }

              function deltaText(v) {
                if (v > 0) return `+${v}`
                return String(v)
              }

              const eventRows = Object.entries(eventDelta)
                .sort((a, b) => Math.abs(b[1]) - Math.abs(a[1]))
                .map(([k, v]) => `<tr><td>${escapeHtml(k)}</td><td class="mono ${deltaClass(v)}">${escapeHtml(deltaText(v))}</td></tr>`)
                .join("")

              diffResultEl.innerHTML = `
                <div class="diff-grid">
                  <div class="diff-card">
                    <h3>Left Task #${escapeHtml(leftTask.id || "")}</h3>
                    ${row("state", leftTask.state || "", rightTask.state || "")}
                    ${row("lane", leftTask.lane || "", rightTask.lane || "")}
                    ${row("source", leftTask.source || "", rightTask.source || "")}
                    ${row("duration(s)", leftMetrics.duration_seconds || 0, rightMetrics.duration_seconds || 0)}
                    ${row("input len", leftMetrics.input_length || 0, rightMetrics.input_length || 0)}
                    ${row("output len", leftMetrics.output_length || 0, rightMetrics.output_length || 0)}
                    ${row("events", leftMetrics.event_count || 0, rightMetrics.event_count || 0)}
                    ${row("turns", leftMetrics.turn_count || 0, rightMetrics.turn_count || 0)}
                  </div>
                  <div class="diff-card">
                    <h3>Right Task #${escapeHtml(rightTask.id || "")}</h3>
                    <div class="diff-row"><span>changed fields</span><span>${escapeHtml(changed)}</span></div>
                    <div class="diff-row"><span>duration Δ</span><span class="mono ${deltaClass(metricDelta.duration_seconds || 0)}">${escapeHtml(deltaText(metricDelta.duration_seconds || 0))}</span></div>
                    <div class="diff-row"><span>input Δ</span><span class="mono ${deltaClass(metricDelta.input_length || 0)}">${escapeHtml(deltaText(metricDelta.input_length || 0))}</span></div>
                    <div class="diff-row"><span>output Δ</span><span class="mono ${deltaClass(metricDelta.output_length || 0)}">${escapeHtml(deltaText(metricDelta.output_length || 0))}</span></div>
                    <div class="diff-row"><span>events Δ</span><span class="mono ${deltaClass(metricDelta.event_count || 0)}">${escapeHtml(deltaText(metricDelta.event_count || 0))}</span></div>
                    <div class="diff-row"><span>turns Δ</span><span class="mono ${deltaClass(metricDelta.turn_count || 0)}">${escapeHtml(deltaText(metricDelta.turn_count || 0))}</span></div>
                    <div class="diff-row"><span>error</span><span>${escapeHtml(rightTask.error_message || "none")}</span></div>
                  </div>
                </div>
                <div class="diff-delta">
                  <table>
                    <thead><tr><th>Event Type</th><th>Right - Left</th></tr></thead>
                    <tbody>${eventRows || `<tr><td colspan="2" class="muted">No event delta</td></tr>`}</tbody>
                  </table>
                </div>
              `
            }

            async function loadRunDiff() {
              const leftId = Number(diffLeftTaskIdEl.value)
              const rightId = Number(diffRightTaskIdEl.value)
              if (!leftId || !rightId) {
                diffResultEl.innerHTML = `<div class="timeline-step muted">Enter both task ids to compare.</div>`
                return
              }

              diffResultEl.innerHTML = `<div class="timeline-step muted">Comparing task #${leftId} and #${rightId}...</div>`
              try {
                const res = await fetch(`/api/run_diff?left_task_id=${leftId}&right_task_id=${rightId}`)
                if (!res.ok) {
                  const body = await res.json().catch(() => ({}))
                  throw new Error(body.error || `HTTP ${res.status}`)
                }
                const data = await res.json()
                renderRunDiff(data)
              } catch (err) {
                diffResultEl.innerHTML = `<div class="timeline-step muted">Run diff error: ${escapeHtml(err.message)}</div>`
              }
            }

            async function refresh() {
              try {
                const [snapshotRes, chatRes] = await Promise.all([
                  fetch('/api/snapshot?limit=40'),
                  fetch(`/api/chat_state?chat_id=${encodeURIComponent(chatId)}&limit=80`)
                ])

                if (!snapshotRes.ok) throw new Error(`snapshot HTTP ${snapshotRes.status}`)
                if (!chatRes.ok) throw new Error(`chat HTTP ${chatRes.status}`)

                const data = await snapshotRes.json()
                const chat = await chatRes.json()

                metaEl.textContent = `db: ${data.db_path} | updated: ${data.generated_at}`
                renderCounts(data.counts || {})
                renderTasks(data.recent_tasks || [])
                renderEvents(data.recent_events || [])
                renderTurns(data.recent_turns || [])
                renderStateCounts(data.task_state_counts || {})
                renderMemories(data.recent_memories || [])
                renderLessons(data.recent_lessons || [])

                renderChat(chat.turns || [], chat.active_run, chat.recent_runs || [])
                renderApprovals(chat.pending_approvals || [])
              } catch (err) {
                metaEl.textContent = `Observer error: ${err.message}`
              }
            }

            chatSendEl.addEventListener("click", sendChat)
            chatInputEl.addEventListener("keydown", (e) => {
              if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
                sendChat()
              }
            })
            timelineLoadEl.addEventListener("click", () => loadTimeline())
            diffLoadEl.addEventListener("click", () => loadRunDiff())

            refresh()
            setInterval(refresh, 1000)
          </script>
        </body>
        </html>
      HTML
    end
  end
end
