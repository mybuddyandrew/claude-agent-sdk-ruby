require "json"

module Skein
  class EventStore
    def initialize(db)
      @db = db
    end

    def append(type:, payload:, task_id: nil)
      @db.execute(
        "INSERT INTO events (type, task_id, payload) VALUES (?, ?, ?)",
        [type, task_id, JSON.generate(payload)]
      )
      @db.last_insert_row_id
    end

    def for_task(task_id)
      @db.execute(
        "SELECT * FROM events WHERE task_id = ? ORDER BY id ASC",
        [task_id]
      ).map { |row| parse_event(row) }
    end

    def recent(type:, limit: 10)
      @db.execute(
        "SELECT * FROM events WHERE type = ? ORDER BY id DESC LIMIT ?",
        [type, limit]
      ).map { |row| parse_event(row) }
    end

    # Delete events older than `days` days. Returns the number deleted.
    def prune!(days: 30)
      cutoff = (Time.now.utc - (days * 86400)).strftime("%Y-%m-%dT%H:%M:%S")
      @db.execute(
        "DELETE FROM events WHERE created_at < ?",
        [cutoff]
      )
      @db.execute("SELECT changes()").first.values.first
    end

    def count
      row = @db.get_first_row("SELECT COUNT(*) AS cnt FROM events")
      row["cnt"].to_i
    end

    private

    def parse_event(row)
      row["payload"] = JSON.parse(row["payload"])
      row
    end
  end
end
