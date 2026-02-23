require "json"

module Skein
  class Memory
    attr_reader :embedder

    def initialize(db:, event_store: nil, embedder: nil)
      @db = db
      @events = event_store
      @embedder = embedder
    end

    def store(content:, category: nil, source: "explicit", source_task_id: nil)
      # Avoid exact duplicates
      existing = @db.get_first_row(
        "SELECT id FROM memories WHERE content = ?", [content]
      )
      if existing
        touch(existing["id"])
        return existing["id"]
      end

      @db.execute(
        "INSERT INTO memories (content, category, source, source_task_id) VALUES (?, ?, ?, ?)",
        [content, category, source, source_task_id]
      )
      id = @db.last_insert_row_id

      # Generate and store embedding if available
      store_embedding(id, content) if semantic_enabled?

      @events&.append(
        type: "memory_stored",
        task_id: source_task_id,
        payload: { memory_id: id, content: content, category: category, source: source }
      )

      id
    end

    def search(query:, limit: 10)
      return recent(limit: limit) if query.nil? || query.strip.empty?

      # Prefer semantic search when available, fall back to keyword
      if semantic_enabled?
        semantic_search(query: query, limit: limit)
      else
        keyword_search(query: query, limit: limit)
      end
    end

    # Keyword-based search (LIKE matching). Always available.
    # Does NOT touch results — call touch explicitly when the user
    # actively recalls a memory (via the Recall tool).
    def keyword_search(query:, limit: 10)
      return recent(limit: limit) if query.nil? || query.strip.empty?

      keywords = query.strip.split(/\s+/)
      conditions = keywords.map { "content LIKE ?" }.join(" AND ")
      params = keywords.map { |k| "%#{k}%" }

      @db.execute(
        "SELECT * FROM memories WHERE #{conditions} ORDER BY access_count DESC, created_at DESC LIMIT ?",
        params + [limit]
      )
    end

    # Semantic vector search using sqlite-vec. Requires embedder + vec extension.
    def semantic_search(query:, limit: 10)
      return keyword_search(query: query, limit: limit) unless semantic_enabled?

      query_vec = @embedder.embed(query)
      query_blob = Embedder.vector_to_blob(query_vec)

      # KNN query via vec0 virtual table
      vec_results = @db.execute(
        "SELECT memory_id, distance FROM memory_embeddings WHERE embedding MATCH ? ORDER BY distance LIMIT ?",
        [query_blob, limit]
      )

      return keyword_search(query: query, limit: limit) if vec_results.empty?

      # Fetch full memory rows for the matched IDs
      ids = vec_results.map { |r| r["memory_id"] }
      # Build a distance lookup for ranking
      distance_by_id = {}
      vec_results.each { |r| distance_by_id[r["memory_id"]] = r["distance"] }

      placeholders = ids.map { "?" }.join(",")
      results = @db.execute(
        "SELECT * FROM memories WHERE id IN (#{placeholders})",
        ids
      )

      # Sort by vector distance (closest first)
      results.sort_by { |r| distance_by_id[r["id"]] || Float::INFINITY }
    end

    def recent(limit: 5)
      @db.execute(
        "SELECT * FROM memories ORDER BY created_at DESC LIMIT ?",
        [limit]
      )
    end

    def top(limit: 10)
      @db.execute(
        "SELECT * FROM memories ORDER BY access_count DESC, created_at DESC LIMIT ?",
        [limit]
      )
    end

    # Combined set for prompt injection: top memories + recent, deduped.
    def all_for_prompt(limit: 20)
      top_ids = top(limit: limit).map { |m| m["id"] }
      recent_ids = recent(limit: 5).map { |m| m["id"] }
      all_ids = (top_ids + recent_ids).uniq.first(limit)

      return [] if all_ids.empty?

      placeholders = all_ids.map { "?" }.join(",")
      @db.execute(
        "SELECT * FROM memories WHERE id IN (#{placeholders}) ORDER BY access_count DESC, created_at DESC",
        all_ids
      )
    end

    def touch(id)
      @db.execute(
        "UPDATE memories SET access_count = access_count + 1, last_accessed_at = strftime('%Y-%m-%dT%H:%M:%f', 'now') WHERE id = ?",
        [id]
      )
    end

    def forget(id)
      @db.execute("DELETE FROM memories WHERE id = ?", [id])
      delete_embedding(id) if @db.vec_enabled
    end

    def count
      row = @db.get_first_row("SELECT COUNT(*) AS cnt FROM memories")
      row["cnt"]
    end

    # Backfill embeddings for all memories that don't have one yet.
    # Returns the number of memories embedded.
    def backfill_embeddings(batch_size: 50)
      return 0 unless semantic_enabled?

      total = 0
      loop do
        # Find memories without embeddings
        rows = @db.execute(
          "SELECT m.id, m.content FROM memories m " \
          "LEFT JOIN memory_embeddings me ON me.memory_id = m.id " \
          "WHERE me.memory_id IS NULL LIMIT ?",
          [batch_size]
        )
        break if rows.empty?

        texts = rows.map { |r| r["content"] }
        embeddings = @embedder.embed_batch(texts)

        rows.each_with_index do |row, i|
          store_embedding(row["id"], nil, vector: embeddings[i])
        end

        total += rows.size
        break if rows.size < batch_size
      end
      total
    end

    # Check if semantic search is available (embedder present + vec extension loaded).
    def semantic_enabled?
      @embedder && @db.vec_enabled
    end

    # Format memories as text for prompt injection.
    def format_for_prompt(limit: 20)
      memories = all_for_prompt(limit: limit)
      return nil if memories.empty?

      lines = memories.map do |m|
        tag = m["category"] ? " [#{m['category']}]" : ""
        "- #{m['content']}#{tag}"
      end

      <<~SECTION
        ## What You Know

        These are facts you've learned about the user from previous conversations.
        Use this context naturally. Don't repeat these facts unless relevant.

        #{lines.join("\n")}
      SECTION
    end

    private

    def store_embedding(memory_id, content, vector: nil)
      vec = vector || @embedder.embed(content)
      blob = Embedder.vector_to_blob(vec)
      @db.execute(
        "INSERT OR REPLACE INTO memory_embeddings (memory_id, embedding) VALUES (?, ?)",
        [memory_id, blob]
      )
    end

    def delete_embedding(memory_id)
      @db.execute(
        "DELETE FROM memory_embeddings WHERE memory_id = ?",
        [memory_id]
      )
    rescue SQLite3::Exception
      # Silently ignore if vec table doesn't exist or other vec errors
    end
  end
end
