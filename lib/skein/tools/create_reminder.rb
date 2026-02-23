require "time"
require "securerandom"

module Skein
  module Tools
    module CreateReminder
      def self.definition
        {
          name: "create_reminder",
          description: "Create a one-shot reminder that fires at a specific time. When the " \
                       "reminder fires, a notification is sent to the user via Telegram.",
          input_schema: {
            type: "object",
            properties: {
              text: { type: "string", description: "The reminder text" },
              fire_at: { type: "string", description: "ISO8601 timestamp, e.g. '2026-02-23T09:00:00Z'" }
            },
            required: ["text", "fire_at"]
          }
        }
      end

      def self.requires_approval?
        true
      end

      def self.execute(input, timers:, chat_id:, **)
        text = input["text"]
        fire_at_str = input["fire_at"]
        return "Error: 'text' is required" unless text.is_a?(String) && !text.empty?
        return "Error: 'fire_at' is required" unless fire_at_str.is_a?(String) && !fire_at_str.empty?

        begin
          fire_at = Time.parse(fire_at_str)
        rescue ArgumentError
          return "Error: invalid fire_at format '#{fire_at_str}'. Use ISO8601 (e.g. '2026-02-23T09:00:00Z')"
        end

        name = "reminder:#{Time.now.to_i}:#{SecureRandom.hex(6)}"
        timers.create(
          name: name,
          next_fire_at: fire_at,
          payload: { text: text, chat_id: chat_id }
        )
        "Reminder created: '#{text}' at #{fire_at.utc.iso8601}"
      end
    end
  end
end
