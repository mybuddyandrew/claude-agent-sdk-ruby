module Skein
  module Tools
    module SendTelegram
      def self.definition
        {
          name: "send_telegram",
          description: "Send a proactive message to the user via Telegram. Use this when you " \
                       "need to notify the user about something or send a follow-up message.",
          input_schema: {
            type: "object",
            properties: {
              text: { type: "string", description: "The message text to send" }
            },
            required: ["text"]
          }
        }
      end

      def self.requires_approval?
        true
      end

      def self.execute(input, telegram:, chat_id:, **)
        text = input["text"]
        return "Error: 'text' is required" unless text.is_a?(String) && !text.empty?

        telegram.send_message(chat_id: chat_id, text: text)
        "Message sent: #{text}"
      end
    end
  end
end
