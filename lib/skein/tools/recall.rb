module Skein
  module Tools
    module Recall
      def self.definition
        {
          name: "recall",
          description: "Search long-term memory for stored facts. Use this when you need to look up " \
                       "something you previously learned about the user, their projects, or preferences.",
          input_schema: {
            type: "object",
            properties: {
              query: {
                type: "string",
                description: "Search keywords (e.g. 'project name', 'deploy key'). Leave empty to list all memories."
              }
            },
            required: []
          }
        }
      end

      def self.requires_approval?
        false
      end

      def self.execute(input, memory:, **)
        results = memory.search(query: input["query"], limit: 15)

        if results.empty?
          "No memories found#{input['query'] ? " matching '#{input['query']}'" : ''}."
        else
          # Touch recalled memories so access_count reflects actual user interest
          results.each { |m| memory.touch(m["id"]) }

          lines = results.map do |m|
            tag = m["category"] ? " [#{m['category']}]" : ""
            "- #{m['content']}#{tag} (accessed #{m['access_count'] + 1}x)"
          end
          "#{results.size} memories found:\n#{lines.join("\n")}"
        end
      end
    end
  end
end
