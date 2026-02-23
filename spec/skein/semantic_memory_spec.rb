require "spec_helper"
require "skein/event_store"
require "skein/memory"
require "skein/embedder"

class StubEmbedder
  attr_reader :dimensions, :embed_count

  def initialize
    @dimensions = 384
    @embed_count = 0
  end

  def embed(text)
    @embed_count += 1
    text_to_vector(text)
  end

  def embed_batch(texts)
    texts.map { |t| embed(t) }
  end

  private

  def text_to_vector(text)
    vec = Array.new(@dimensions, 0.0)
    return vec if text.nil? || text.strip.empty?
    words = text.downcase.strip.split(/\s+/)
    words.each do |word|
      idx = word.bytes.sum % @dimensions
      vec[idx] = 1.0
    end
    norm = Math.sqrt(vec.sum { |v| v * v })
    vec.map! { |v| norm > 0 ? v / norm : 0.0 }
    vec
  end
end

RSpec.describe "Semantic Memory" do
  let(:db) { Skein::DB.new(":memory:", vec: false) }
  let(:events) { Skein::EventStore.new(db) }
  let(:embedder) { StubEmbedder.new }

  describe "semantic_enabled?" do
    it "is disabled without embedder" do
      memory = Skein::Memory.new(db: db, event_store: events)
      expect(memory.semantic_enabled?).to be_falsey
    end

    it "is disabled without vec extension" do
      memory = Skein::Memory.new(db: db, event_store: events, embedder: embedder)
      expect(memory.semantic_enabled?).to be_falsey
      expect(db.vec_enabled).to be_falsey
    end
  end

  describe "#search" do
    it "falls back to keyword search without embedder" do
      memory = Skein::Memory.new(db: db, event_store: events)
      memory.store(content: "User likes Ruby programming", category: "preference")
      memory.store(content: "User works on Deckhand project", category: "project")
      results = memory.search(query: "Ruby")
      expect(results.size).to eq(1)
      expect(results.first["content"]).to eq("User likes Ruby programming")
    end

    it "falls back to keyword search when vec not loaded" do
      memory = Skein::Memory.new(db: db, event_store: events, embedder: embedder)
      memory.store(content: "Andrew loves coffee", category: "preference")
      memory.store(content: "Project uses Rails", category: "project")
      results = memory.search(query: "coffee")
      expect(results.size).to eq(1)
      expect(results.first["content"]).to eq("Andrew loves coffee")
    end
  end

  describe "#store" do
    it "skips embedding without vec" do
      memory = Skein::Memory.new(db: db, event_store: events, embedder: embedder)
      id = memory.store(content: "A test fact")
      expect(id).to be > 0
      expect(embedder.embed_count).to eq(0)
    end
  end

  describe "#keyword_search" do
    it "is always available" do
      memory = Skein::Memory.new(db: db, event_store: events, embedder: embedder)
      memory.store(content: "User prefers dark mode")
      memory.store(content: "User prefers light theme")
      results = memory.keyword_search(query: "dark")
      expect(results.size).to eq(1)
      expect(results.first["content"]).to eq("User prefers dark mode")
    end

    it "returns recent entries for empty query" do
      memory = Skein::Memory.new(db: db, event_store: events)
      memory.store(content: "Fact one")
      memory.store(content: "Fact two")
      results = memory.keyword_search(query: "", limit: 10)
      expect(results.size).to eq(2)
    end
  end

  describe "vector blob roundtrip" do
    it "preserves embedded vector through blob conversion" do
      vec = embedder.embed("test text")
      blob = Skein::Embedder.vector_to_blob(vec)
      restored = Skein::Embedder.blob_to_vector(blob)
      expect(restored.size).to eq(vec.size)
      vec.each_with_index do |v, i|
        expect(restored[i]).to be_within(0.0001).of(v)
      end
    end
  end

  describe "#embedder" do
    it "is accessible when provided" do
      memory = Skein::Memory.new(db: db, embedder: embedder)
      expect(memory.embedder).to eq(embedder)
    end

    it "is nil by default" do
      memory = Skein::Memory.new(db: db)
      expect(memory.embedder).to be_nil
    end
  end

  describe "store and search without embedder" do
    it "finds memories by keyword" do
      memory = Skein::Memory.new(db: db, event_store: events)
      memory.store(content: "User's name is Andrew", category: "fact")
      memory.store(content: "Working on Deckhand project", category: "project")
      results = memory.search(query: "Andrew")
      expect(results.size).to eq(1)
      expect(results.first["content"]).to eq("User's name is Andrew")
    end
  end

  describe "#forget" do
    it "removes a memory without vec" do
      memory = Skein::Memory.new(db: db, event_store: events)
      id = memory.store(content: "Forget me")
      expect(memory.count).to eq(1)
      memory.forget(id)
      expect(memory.count).to eq(0)
    end
  end

  describe "deduplication" do
    it "still works with embedder" do
      memory = Skein::Memory.new(db: db, event_store: events, embedder: embedder)
      id1 = memory.store(content: "A fact")
      id2 = memory.store(content: "A fact")
      expect(memory.count).to eq(1)
      expect(id2).to eq(id1)
    end
  end

  describe "#format_for_prompt" do
    it "includes expected content" do
      memory = Skein::Memory.new(db: db, event_store: events)
      memory.store(content: "User's name is Andrew", category: "fact")
      text = memory.format_for_prompt
      expect(text).to include("What You Know")
      expect(text).to include("Andrew")
      expect(text).to include("[fact]")
    end
  end
end
