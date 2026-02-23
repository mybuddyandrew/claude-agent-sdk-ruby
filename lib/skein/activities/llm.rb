module Skein
  module Activities
    class LLM
      def initialize(api_key:, model:)
        require "anthropic"
        @client = Anthropic::Client.new(api_key: api_key)
        @model = model
      rescue LoadError
        raise LoadError, "Anthropic SDK not installed. Add `gem 'anthropic'` or use Activities::ClaudeCode."
      end

      def chat(system:, messages:, tools: [], max_tokens: 4096)
        params = {
          model: @model,
          max_tokens: max_tokens,
          system: system,
          messages: messages,
        }
        params[:tools] = format_tools(tools) unless tools.empty?

        @client.messages.create(**params)
      end

      private

      def format_tools(tools)
        tools.map do |t|
          {
            name: t[:name],
            description: t[:description],
            input_schema: t[:input_schema],
          }
        end
      end
    end
  end
end
