require "json"
require "webrick"

module Skein
  class ObserverServer
    DEFAULT_HOST = "127.0.0.1"
    DEFAULT_PORT = 4310

    def initialize(config: Config.new, host: nil, port: nil, logger: nil)
      @config = config
      @host = host || ENV.fetch("SKEIN_WATCH_HOST", DEFAULT_HOST)
      @port = (port || ENV.fetch("SKEIN_WATCH_PORT", DEFAULT_PORT.to_s)).to_i
      @logger = logger
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

      Signal.trap("INT") { server.shutdown }
      Signal.trap("TERM") { server.shutdown }

      log "Observer UI listening at http://#{@host}:#{@port}"
      server.start
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
            main { padding: 18px 22px 30px; display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }
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
          </main>
          <script>
            const countsEl = document.getElementById("counts")
            const metaEl = document.getElementById("meta")
            const tasksEl = document.getElementById("tasks")
            const eventsEl = document.getElementById("events")
            const turnsEl = document.getElementById("turns")
            const stateCountsEl = document.getElementById("stateCounts")

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

            async function refresh() {
              try {
                const res = await fetch('/api/snapshot?limit=40')
                if (!res.ok) throw new Error(`HTTP ${res.status}`)
                const data = await res.json()
                metaEl.textContent = `db: ${data.db_path} | updated: ${data.generated_at}`
                renderCounts(data.counts || {})
                renderTasks(data.recent_tasks || [])
                renderEvents(data.recent_events || [])
                renderTurns(data.recent_turns || [])
                renderStateCounts(data.task_state_counts || {})
              } catch (err) {
                metaEl.textContent = `Observer error: ${err.message}`
              }
            }

            refresh()
            setInterval(refresh, 1000)
          </script>
        </body>
        </html>
      HTML
    end
  end
end
