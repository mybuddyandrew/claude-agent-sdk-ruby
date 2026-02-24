require "json"
require "webrick"
require "thread"

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
            main { padding: 18px 22px 30px; display: grid; grid-template-columns: repeat(auto-fit, minmax(420px, 1fr)); gap: 14px; }
            section { background: var(--panel); border: 1px solid var(--border); border-radius: 12px; overflow: hidden; }
            section h2 { margin: 0; padding: 10px 12px; font-size: 14px; border-bottom: 1px solid var(--border); background: #faf7ef; }
            table { width: 100%; border-collapse: collapse; }
            th, td { text-align: left; font-size: 12px; padding: 6px 8px; border-bottom: 1px solid #f0eee8; vertical-align: top; }
            th { color: var(--muted); font-weight: 600; }
            .mono { font-family: ui-monospace, Menlo, monospace; }
            .scroll { max-height: 42vh; overflow: auto; }
            @media (max-width: 980px) { main { grid-template-columns: 1fr; } }
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

            refresh()
            setInterval(refresh, 1000)
          </script>
        </body>
        </html>
      HTML
    end
  end
end
