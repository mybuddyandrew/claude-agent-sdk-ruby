module Skein
  module RuntimeHelpers
    private

    def skill_context
      {
        memory: @memory, timers: @timers, lessons: @lessons,
        events: @events, db: @db, config: @config, logger: method(:log),
      }
    end

    def build_embedder
      return nil unless @config.embedding_enabled
      Embedder.new(model_name: @config.embedding_model)
    rescue LoadError => e
      log "Embeddings disabled: #{e.message}"
      nil
    end
  end
end
