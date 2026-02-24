require "spec_helper"
require "skein/event_store"
require "skein/task"
require "skein/lesson"

RSpec.describe Skein::Lesson do
  before do
    @db = create_test_db
    @events = Skein::EventStore.new(@db)
    @tasks = Skein::Task.new(db: @db, event_store: @events)
    @lessons = Skein::Lesson.new(db: @db, event_store: @events)
  end

  it "store and count" do
    expect(@lessons.count).to eq(0)
    @lessons.store(content: "Be more concise with factual questions", category: "tone")
    expect(@lessons.count).to eq(1)
  end

  it "store returns id" do
    id = @lessons.store(content: "Use tools proactively", category: "tool_use")
    expect(id).to be_a(Integer)
    expect(id).to be > 0
  end

  it "store deduplicates" do
    id1 = @lessons.store(content: "Be concise")
    id2 = @lessons.store(content: "Be concise")
    expect(@lessons.count).to eq(1)
    expect(id2).to eq(id1)
  end

  it "store deduplicates case and surrounding whitespace variants" do
    id1 = @lessons.store(content: "Be concise")
    id2 = @lessons.store(content: "  be concise  ")
    expect(@lessons.count).to eq(1)
    expect(id2).to eq(id1)
  end

  it "store dedup bumps applied count" do
    @lessons.store(content: "Be concise")
    @lessons.store(content: "Be concise")
    results = @lessons.top(limit: 1)
    expect(results.first["applied_count"]).to eq(1)
  end

  it "store logs event" do
    @lessons.store(content: "A lesson")
    events = @events.recent(type: "lesson_stored", limit: 1)
    expect(events.size).to eq(1)
    expect(events.first["payload"]["content"]).to eq("A lesson")
  end

  it "top ordered by effectiveness" do
    low_id = @lessons.store(content: "Low effectiveness")
    high_id = @lessons.store(content: "High effectiveness")
    @db.execute("UPDATE lessons SET effectiveness = 5 WHERE id = ?", [high_id])
    @db.execute("UPDATE lessons SET effectiveness = -1 WHERE id = ?", [low_id])
    results = @lessons.top(limit: 2)
    expect(results.first["content"]).to eq("High effectiveness")
  end

  it "recent" do
    @lessons.store(content: "Old lesson")
    @lessons.store(content: "New lesson")
    results = @lessons.recent(limit: 1)
    expect(results.size).to eq(1)
    expect(results.first["content"]).to eq("New lesson")
  end

  it "all_for_prompt combines top and recent" do
    ids = (1..5).map { |i| @lessons.store(content: "Lesson #{i}") }
    @db.execute("UPDATE lessons SET effectiveness = 10 WHERE id = ?", [ids[0]])
    results = @lessons.all_for_prompt(limit: 5)
    expect(results.size).to be <= 5
    expect(results.any? { |r| r["content"] == "Lesson 1" }).to be_truthy
    expect(results.any? { |r| r["content"] == "Lesson 5" }).to be_truthy
  end

  it "all_for_prompt empty" do
    expect(@lessons.all_for_prompt).to eq([])
  end

  it "touch bumps applied count" do
    id = @lessons.store(content: "Touchable lesson")
    @lessons.touch(id)
    @lessons.touch(id)
    results = @lessons.top(limit: 1)
    expect(results.first["applied_count"]).to eq(2)
  end

  it "rate_for_task" do
    task1_id = @tasks.create(source: "cli", chat_id: "cli")
    task2_id = @tasks.create(source: "cli", chat_id: "cli")
    @lessons.store(content: "Lesson from task 1", source_task_id: task1_id)
    @lessons.store(content: "Another from task 1", source_task_id: task1_id)
    @lessons.store(content: "Lesson from task 2", source_task_id: task2_id)
    @lessons.rate_for_task(task_id: task1_id, delta: 2)
    task1_lessons = @db.execute("SELECT * FROM lessons WHERE source_task_id = ?", [task1_id])
    task1_lessons.each { |l| expect(l["effectiveness"]).to eq(2) }
    task2_lesson = @db.execute("SELECT * FROM lessons WHERE source_task_id = ?", [task2_id]).first
    expect(task2_lesson["effectiveness"]).to eq(0)
  end

  it "rate_for_task negative" do
    task_id = @tasks.create(source: "cli", chat_id: "cli")
    @lessons.store(content: "Bad lesson", source_task_id: task_id)
    @lessons.rate_for_task(task_id: task_id, delta: -2)
    result = @db.execute("SELECT * FROM lessons WHERE source_task_id = ?", [task_id]).first
    expect(result["effectiveness"]).to eq(-2)
  end

  it "prune removes low effectiveness" do
    @lessons.store(content: "Good lesson")
    bad_id = @lessons.store(content: "Bad lesson")
    @db.execute("UPDATE lessons SET effectiveness = -3 WHERE id = ?", [bad_id])
    pruned = @lessons.prune!
    expect(pruned).to eq(1)
    expect(@lessons.count).to eq(1)
  end

  it "prune keeps borderline" do
    id = @lessons.store(content: "Borderline lesson")
    @db.execute("UPDATE lessons SET effectiveness = -2 WHERE id = ?", [id])
    pruned = @lessons.prune!
    expect(pruned).to eq(0)
    expect(@lessons.count).to eq(1)
  end

  it "forget" do
    id = @lessons.store(content: "Forget me")
    expect(@lessons.count).to eq(1)
    @lessons.forget(id)
    expect(@lessons.count).to eq(0)
  end

  it "format_for_prompt with lessons" do
    @lessons.store(content: "Be concise with factual questions", category: "tone")
    @lessons.store(content: "Use read_file proactively", category: "tool_use")
    text = @lessons.format_for_prompt
    expect(text).to include("Behavioral Lessons")
    expect(text).to include("Be concise with factual questions")
    expect(text).to include("[tone]")
    expect(text).to include("[tool_use]")
  end

  it "format_for_prompt nil when empty" do
    expect(@lessons.format_for_prompt).to be_nil
  end

  it "format_for_prompt does not inflate applied count" do
    @lessons.store(content: "Applied lesson")
    @lessons.format_for_prompt
    results = @lessons.top(limit: 1)
    expect(results.first["applied_count"]).to eq(0),
      "format_for_prompt should not increment applied_count (only rate_for_task should)"
  end

  it "category optional" do
    @lessons.store(content: "No category")
    results = @lessons.recent(limit: 1)
    expect(results.first["category"]).to be_nil
  end

  it "source_task_id optional" do
    @lessons.store(content: "No task")
    results = @lessons.recent(limit: 1)
    expect(results.first["source_task_id"]).to be_nil
  end
end
