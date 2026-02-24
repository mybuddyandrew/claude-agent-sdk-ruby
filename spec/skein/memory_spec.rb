require "spec_helper"
require "skein/event_store"
require "skein/memory"

RSpec.describe Skein::Memory do
  before do
    @db = create_test_db
    @events = Skein::EventStore.new(@db)
    @memory = Skein::Memory.new(db: @db, event_store: @events)
  end

  it "store and count" do
    expect(@memory.count).to eq(0)
    @memory.store(content: "User's name is Andrew", category: "fact")
    expect(@memory.count).to eq(1)
  end

  it "store returns id" do
    id = @memory.store(content: "Prefers dark mode", category: "preference")
    expect(id).to be_a(Integer)
    expect(id).to be > 0
  end

  it "store deduplicates" do
    id1 = @memory.store(content: "User's name is Andrew")
    id2 = @memory.store(content: "User's name is Andrew")
    expect(@memory.count).to eq(1)
    expect(id2).to eq(id1)
  end

  it "store deduplicates case and surrounding whitespace variants" do
    id1 = @memory.store(content: "User likes Ruby")
    id2 = @memory.store(content: "  user likes ruby  ")
    expect(@memory.count).to eq(1)
    expect(id2).to eq(id1)
  end

  it "store dedup bumps access count" do
    @memory.store(content: "User's name is Andrew")
    @memory.store(content: "User's name is Andrew")
    results = @memory.top(limit: 1)
    expect(results.first["access_count"]).to eq(1)
  end

  it "store logs event" do
    @memory.store(content: "A fact")
    events = @events.recent(type: "memory_stored", limit: 1)
    expect(events.size).to eq(1)
    expect(events.first["payload"]["content"]).to eq("A fact")
  end

  it "search by keyword" do
    @memory.store(content: "User's name is Andrew", category: "fact")
    @memory.store(content: "Working on Deckhand project", category: "project")
    @memory.store(content: "Prefers morning meetings", category: "preference")
    results = @memory.search(query: "Andrew")
    expect(results.size).to eq(1)
    expect(results.first["content"]).to eq("User's name is Andrew")
  end

  it "search multi keyword" do
    @memory.store(content: "Working on Deckhand Rails CRM project")
    results = @memory.search(query: "Deckhand project")
    expect(results.size).to eq(1)
  end

  it "search empty returns recent" do
    @memory.store(content: "Fact one")
    @memory.store(content: "Fact two")
    results = @memory.search(query: "", limit: 10)
    expect(results.size).to eq(2)
  end

  it "search no results" do
    @memory.store(content: "User's name is Andrew")
    results = @memory.search(query: "nonexistent")
    expect(results.size).to eq(0)
  end

  it "search does not bump access count" do
    @memory.store(content: "User's name is Andrew")
    @memory.search(query: "Andrew")
    results = @memory.top(limit: 1)
    expect(results.first["access_count"]).to eq(0),
      "search should not inflate access_count — only explicit recall via tool should"
  end

  it "touch bumps access count" do
    id = @memory.store(content: "User's name is Andrew")
    @memory.touch(id)
    results = @memory.top(limit: 1)
    expect(results.first["access_count"]).to eq(1)
  end

  it "recent" do
    @memory.store(content: "Old fact")
    @memory.store(content: "New fact")
    results = @memory.recent(limit: 1)
    expect(results.size).to eq(1)
    expect(results.first["content"]).to eq("New fact")
  end

  it "top ordered by access count" do
    @memory.store(content: "Rarely accessed")
    frequent_id = @memory.store(content: "Frequently accessed")
    3.times { @memory.touch(frequent_id) }
    results = @memory.top(limit: 2)
    expect(results.first["content"]).to eq("Frequently accessed")
  end

  it "all_for_prompt combines top and recent" do
    ids = (1..5).map { |i| @memory.store(content: "Fact #{i}") }
    10.times { @memory.touch(ids[0]) }
    results = @memory.all_for_prompt(limit: 5)
    expect(results.size).to be <= 5
    expect(results.any? { |r| r["content"] == "Fact 1" }).to be_truthy
    expect(results.any? { |r| r["content"] == "Fact 5" }).to be_truthy
  end

  it "all_for_prompt empty" do
    expect(@memory.all_for_prompt).to eq([])
  end

  it "forget" do
    id = @memory.store(content: "Forget me")
    expect(@memory.count).to eq(1)
    @memory.forget(id)
    expect(@memory.count).to eq(0)
  end

  it "format_for_prompt with memories" do
    @memory.store(content: "User's name is Andrew", category: "fact")
    @memory.store(content: "Prefers concise answers", category: "preference")
    text = @memory.format_for_prompt
    expect(text).to include("What You Know")
    expect(text).to include("User's name is Andrew")
    expect(text).to include("[fact]")
    expect(text).to include("[preference]")
  end

  it "format_for_prompt nil when empty" do
    expect(@memory.format_for_prompt).to be_nil
  end

  it "category optional" do
    @memory.store(content: "No category")
    results = @memory.recent(limit: 1)
    expect(results.first["category"]).to be_nil
  end

  it "source defaults to explicit" do
    @memory.store(content: "Explicit memory")
    results = @memory.recent(limit: 1)
    expect(results.first["source"]).to eq("explicit")
  end

  it "extracted source" do
    @memory.store(content: "Auto-extracted", source: "extracted")
    results = @memory.recent(limit: 1)
    expect(results.first["source"]).to eq("extracted")
  end
end
