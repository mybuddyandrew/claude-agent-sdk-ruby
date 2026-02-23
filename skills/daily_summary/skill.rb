module Skein
  module Skills
    class DailySummary < Skein::Skill
      # No custom tools — this skill only uses hooks and schedules.

      # Track completed tasks during the day for the summary.
      def after_task(task, result)
        return unless task["chat_id"]  # skip system tasks

        @completed_today ||= []
        @completed_today << {
          id: task["id"],
          input: (task["input_text"] || "")[0, 80],
          result_len: result&.length || 0,
          at: Time.now.utc.iso8601,
        }
      end

      # Scheduled handler — fires once per day.
      # Builds a summary of the last 24 hours and creates a task to deliver it.
      def on_schedule(timer)
        summary = build_summary
        return if summary.nil?  # nothing to summarize

        # Create a task that asks Claude to deliver the summary
        task_input = <<~PROMPT
          Deliver this daily activity summary to the user. Be concise and friendly.
          Format it nicely with sections. If there's nothing notable, just say so briefly.

          #{summary}
        PROMPT

        # Find the most recent chat_id to deliver to
        chat_id = most_recent_chat_id
        return unless chat_id

        tasks = context[:tasks] || context[:timers]&.instance_variable_get(:@db)
        return unless tasks.respond_to?(:create)

        tasks.create(
          source: "skill:daily_summary",
          chat_id: chat_id,
          input_text: task_input
        )

        # Reset daily counters
        @completed_today = []
      end

      private

      def build_summary
        parts = []

        # Tasks completed
        completed = @completed_today || []
        if completed.any?
          parts << "## Tasks Completed (#{completed.size})"
          completed.each do |t|
            parts << "- #{t[:input]} (#{t[:result_len]} chars)"
          end
        end

        # Recent memories stored
        if memory
          recent_memories = db.execute(
            "SELECT content, category FROM memories WHERE created_at > datetime('now', '-1 day') ORDER BY created_at DESC LIMIT 10"
          )
          if recent_memories.any?
            parts << "\n## New Memories (#{recent_memories.size})"
            recent_memories.each do |m|
              tag = m["category"] ? " [#{m['category']}]" : ""
              parts << "- #{m['content']}#{tag}"
            end
          end
        end

        # Recent lessons
        if db
          recent_lessons = db.execute(
            "SELECT content, category FROM lessons WHERE created_at > datetime('now', '-1 day') ORDER BY created_at DESC LIMIT 10"
          )
          if recent_lessons.any?
            parts << "\n## New Lessons (#{recent_lessons.size})"
            recent_lessons.each do |l|
              tag = l["category"] ? " [#{l['category']}]" : ""
              parts << "- #{l['content']}#{tag}"
            end
          end
        end

        # Events summary
        if events
          event_count = events.count rescue 0
          parts << "\n## Events: #{event_count} total in store" if event_count > 0
        end

        return nil if parts.empty?
        parts.join("\n")
      end

      def most_recent_chat_id
        return nil unless db
        row = db.get_first_row(
          "SELECT chat_id FROM conversation_turns WHERE chat_id IS NOT NULL ORDER BY id DESC LIMIT 1"
        )
        row&.fetch("chat_id", nil)
      end
    end
  end
end
