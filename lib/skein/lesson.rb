require "json"

module Skein
  class Lesson
    def initialize(db:, event_store: nil)
      @db = db
      @events = event_store
    end

    def store(content:, category: nil, source_task_id: nil)
      # Avoid exact duplicates — bump applied_count instead
      existing = @db.get_first_row(
        "SELECT id FROM lessons WHERE content = ?", [content]
      )
      if existing
        touch(existing["id"])
        return existing["id"]
      end

      @db.execute(
        "INSERT INTO lessons (content, category, source_task_id) VALUES (?, ?, ?)",
        [content, category, source_task_id]
      )
      id = @db.last_insert_row_id

      @events&.append(
        type: "lesson_stored",
        task_id: source_task_id,
        payload: { lesson_id: id, content: content, category: category }
      )

      id
    end

    def top(limit: 10)
      @db.execute(
        "SELECT * FROM lessons ORDER BY effectiveness DESC, applied_count DESC, created_at DESC LIMIT ?",
        [limit]
      )
    end

    def recent(limit: 5)
      @db.execute(
        "SELECT * FROM lessons ORDER BY created_at DESC LIMIT ?",
        [limit]
      )
    end

    # Combined set for prompt injection: top lessons + recent, deduped.
    def all_for_prompt(limit: 10)
      top_ids = top(limit: limit).map { |l| l["id"] }
      recent_ids = recent(limit: 3).map { |l| l["id"] }
      all_ids = (top_ids + recent_ids).uniq.first(limit)

      return [] if all_ids.empty?

      placeholders = all_ids.map { "?" }.join(",")
      @db.execute(
        "SELECT * FROM lessons WHERE id IN (#{placeholders}) ORDER BY effectiveness DESC, applied_count DESC",
        all_ids
      )
    end

    def touch(id)
      @db.execute(
        "UPDATE lessons SET applied_count = applied_count + 1 WHERE id = ?",
        [id]
      )
    end

    # Adjust effectiveness for all lessons extracted from a given task.
    # delta: positive for good conversations, negative for bad ones.
    def rate_for_task(task_id:, delta:)
      @db.execute(
        "UPDATE lessons SET effectiveness = effectiveness + ? WHERE source_task_id = ?",
        [delta, task_id]
      )
    end

    # Self-cleaning: remove lessons that have proven unhelpful.
    def prune!
      pruned = @db.execute(
        "SELECT id, content FROM lessons WHERE effectiveness < -2"
      )
      @db.execute("DELETE FROM lessons WHERE effectiveness < -2")
      pruned.size
    end

    def forget(id)
      @db.execute("DELETE FROM lessons WHERE id = ?", [id])
    end

    def count
      row = @db.get_first_row("SELECT COUNT(*) AS cnt FROM lessons")
      row["cnt"]
    end

    # Format lessons as text for prompt injection.
    # Note: does NOT increment applied_count — that should only happen
    # when a conversation is rated (via rate_for_task), not on every prompt.
    def format_for_prompt(limit: 10)
      lessons = all_for_prompt(limit: limit)
      return nil if lessons.empty?

      lines = lessons.map do |l|
        tag = l["category"] ? " [#{l['category']}]" : ""
        "- #{l['content']}#{tag}"
      end

      <<~SECTION
        ## Behavioral Lessons

        These are patterns you've learned about how to be a better assistant.
        Apply these naturally. They reflect what has worked well in past conversations.

        #{lines.join("\n")}
      SECTION
    end
  end
end
