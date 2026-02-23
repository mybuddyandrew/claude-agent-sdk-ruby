module Skein
  class Embedder
    DIMENSIONS = 384
    DEFAULT_MODEL = "sentence-transformers/all-MiniLM-L6-v2"

    attr_reader :dimensions

    def initialize(model_name: DEFAULT_MODEL)
      require "informers"

      @model_name = model_name
      @dimensions = DIMENSIONS
      @pipeline = Informers.pipeline("embedding", @model_name)
    end

    # Embed a single text string. Returns an Array of floats (length == dimensions).
    def embed(text)
      return Array.new(@dimensions, 0.0) if text.nil? || text.strip.empty?

      result = @pipeline.(text)
      # pipeline returns a single embedding array for a single string
      result.is_a?(Array) && result.first.is_a?(Array) ? result.first : result
    end

    # Embed multiple texts. Returns Array of Arrays of floats.
    def embed_batch(texts)
      return [] if texts.nil? || texts.empty?

      non_empty = texts.map { |t| (t.nil? || t.strip.empty?) ? nil : t }

      results = Array.new(texts.size)
      to_embed = []
      indices = []

      non_empty.each_with_index do |t, i|
        if t.nil?
          results[i] = Array.new(@dimensions, 0.0)
        else
          to_embed << t
          indices << i
        end
      end

      unless to_embed.empty?
        embeddings = @pipeline.(to_embed)
        # Normalize: single text returns flat array, multiple returns nested
        if to_embed.size == 1
          embeddings = [embeddings] unless embeddings.first.is_a?(Array)
        end
        indices.each_with_index do |result_idx, batch_idx|
          results[result_idx] = embeddings[batch_idx]
        end
      end

      results
    end

    # Serialize a float vector to the compact binary format sqlite-vec expects.
    def self.vector_to_blob(vector)
      vector.pack("f*")
    end

    # Deserialize a sqlite-vec binary blob back to a float array.
    def self.blob_to_vector(blob)
      blob.unpack("f*")
    end
  end
end
