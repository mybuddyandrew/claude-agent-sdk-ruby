require "json"
require "time"

module Skein
  class Timer
    def initialize(db:, event_store:)
      @db = db
      @event_store = event_store
    end

    def create(name:, next_fire_at:, interval_seconds: nil, payload: {})
      @db.execute(
        "INSERT OR REPLACE INTO timers (name, next_fire_at, interval_seconds, payload) VALUES (?, ?, ?, ?)",
        [name, format_time(next_fire_at), interval_seconds, JSON.generate(payload)]
      )
      id = @db.last_insert_row_id
      @event_store.append(type: "timer_created", payload: {
        name: name, next_fire_at: format_time(next_fire_at), interval_seconds: interval_seconds
      })
      id
    end

    def due_timers
      now = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%L")
      @db.execute(
        "SELECT * FROM timers WHERE enabled = 1 AND next_fire_at <= ? ORDER BY next_fire_at ASC",
        [now]
      ).map { |row| row["payload"] = JSON.parse(row["payload"] || "{}"); row }
    end

    def mark_fired!(timer_id)
      timer = @db.get_first_row("SELECT * FROM timers WHERE id = ?", [timer_id])
      return unless timer

      if timer["interval_seconds"]
        # Advance from now (not old fire time) to prevent burst-firing after outages
        new_fire = Time.now.utc + timer["interval_seconds"]
        @db.execute(
          "UPDATE timers SET next_fire_at = ? WHERE id = ?",
          [format_time(new_fire), timer_id]
        )
      else
        @db.execute("UPDATE timers SET enabled = 0 WHERE id = ?", [timer_id])
      end

      @event_store.append(type: "timer_fired", payload: { timer_id: timer_id, name: timer["name"] })
    end

    def find_by_name(name)
      @db.get_first_row("SELECT * FROM timers WHERE name = ?", [name])
    end

    private

    def format_time(time)
      case time
      when Time
        time.utc.strftime("%Y-%m-%dT%H:%M:%S.%L")
      when String
        time
      else
        time.to_s
      end
    end
  end
end
