module Skein
  module Tools
    module Remember
      def self.definition
        {
          name: "remember",
          description: "Store an important fact, preference, or piece of information to long-term memory. " \
                       "Use this proactively when you learn something worth remembering about the user.",
          input_schema: {
            type: "object",
            properties: {
              content: { type: "string", description: "The fact to remember (e.g. 'User prefers morning meetings')" },
              category: {
                type: "string",
                description: "Optional category: fact, preference, person, project, or decision"
              }
            },
            required: ["content"]
          }
        }
      end

      def self.requires_approval?
        false
      end

      def self.execute(input, memory:, task_id: nil, **)
        content = input["content"]
        return "Error: 'content' is required" unless content.is_a?(String) && !content.empty?

        memory.store(
          content: content,
          category: input["category"],
          source: "explicit",
          source_task_id: task_id
        )
        "Remembered: #{content}"
      end
    end
  end
end
