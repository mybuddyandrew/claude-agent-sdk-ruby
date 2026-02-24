require "spec_helper"
require "skein"

RSpec.describe Skein::Repl do
  let(:repl) { described_class.allocate }

  describe ".new" do
    it "initializes DB with configured busy timeout" do
      config = Skein::Config.new(
        db_path: "/tmp/skein-repl.db",
        db_busy_timeout_ms: 4321,
        embedding_enabled: false
      )

      db = instance_double(Skein::DB)
      events = instance_double(Skein::EventStore)
      tasks = instance_double(Skein::Task)
      timers = instance_double(Skein::Timer)
      memory = instance_double(Skein::Memory)
      lessons = instance_double(Skein::Lesson)
      tool_executor = instance_double(Skein::ToolExecutor)
      skill_registry = instance_double(Skein::SkillRegistry)
      sdk_client = instance_double(Skein::SdkClient)
      agent = instance_double(Skein::Agent)

      allow(Skein::Config).to receive(:new).and_return(config)
      expect(Skein::DB).to receive(:new).with("/tmp/skein-repl.db", busy_timeout_ms: 4321).and_return(db)
      allow(Skein::EventStore).to receive(:new).with(db).and_return(events)
      allow(Skein::Task).to receive(:new).with(db: db, event_store: events).and_return(tasks)
      allow(Skein::Timer).to receive(:new).with(db: db, event_store: events).and_return(timers)
      allow(Skein::Memory).to receive(:new).with(db: db, event_store: events, embedder: nil).and_return(memory)
      allow(Skein::Lesson).to receive(:new).with(db: db, event_store: events).and_return(lessons)
      allow(Skein::ToolExecutor).to receive(:new).with(memory: memory, timers: timers, config: config).and_return(tool_executor)
      allow(Skein::SkillRegistry).to receive(:new).and_return(skill_registry)
      allow(skill_registry).to receive(:load_all!)
      allow(skill_registry).to receive(:register_tools!).with(tool_executor)
      allow(Skein::SdkClient).to receive(:new).and_return(sdk_client)
      allow(Skein::Agent).to receive(:new).and_return(agent)
      allow(Signal).to receive(:trap)

      described_class.new
    end
  end

  describe "#format_tool_input" do
    it "formats hash inputs as key-value lines" do
      lines = repl.send(:format_tool_input, { "file_path" => "docs/note.md", "mode" => "append" })

      expect(lines).to include("file_path: docs/note.md")
      expect(lines).to include("mode: append")
    end

    it "truncates long string values" do
      long = "x" * 200
      lines = repl.send(:format_tool_input, { "content" => long })

      expect(lines.first).to end_with("...")
      expect(lines.first.length).to be < 95
    end

    it "falls back to string for non-hash input" do
      lines = repl.send(:format_tool_input, "raw input")

      expect(lines).to eq(["raw input"])
    end
  end

  describe "#render_markdown_line" do
    it "formats headers" do
      rendered = repl.send(:render_markdown_line, "## Heading")

      expect(rendered).to include("Heading")
      expect(rendered).to include(Skein::Repl::BOLD)
      expect(rendered).to include(Skein::Repl::MAGENTA)
    end

    it "formats inline code" do
      rendered = repl.send(:render_markdown_line, "Use `bundle exec rspec`")

      expect(rendered).to include("bundle exec rspec")
      expect(rendered).to include(Skein::Repl::BG_GRAY)
    end
  end

  describe "#render_markdown" do
    it "renders fenced code blocks with background styling" do
      text = "```ruby\nputs 'hi'\n```"
      rendered = repl.send(:render_markdown, text)

      expect(rendered).to include("puts 'hi'")
      expect(rendered).to include(Skein::Repl::BG_GRAY)
    end
  end

  describe "#request_approval" do
    it "returns allow for yes and restarts spinner" do
      allow(repl).to receive(:stop_spinner!)
      allow(repl).to receive(:start_spinner!)
      allow(repl).to receive(:puts)
      allow(repl).to receive(:print)
      allow(repl).to receive(:read_line).and_return("yes\n")

      result = repl.request_approval("chat", "Bash", { "command" => "ls" })

      expect(result).to eq("allow")
      expect(repl).to have_received(:start_spinner!)
    end

    it "returns deny for non-yes answers" do
      allow(repl).to receive(:stop_spinner!)
      allow(repl).to receive(:start_spinner!)
      allow(repl).to receive(:puts)
      allow(repl).to receive(:print)
      allow(repl).to receive(:read_line).and_return("no\n")

      result = repl.request_approval("chat", "Bash", { "command" => "ls" })

      expect(result).to eq("deny")
      expect(repl).not_to have_received(:start_spinner!)
    end
  end

  describe "#handle_command" do
    it "returns false for non-command input" do
      expect(repl.send(:handle_command, "hello")).to be(false)
    end

    it "handles /help" do
      allow(repl).to receive(:puts)

      result = repl.send(:handle_command, "/help")

      expect(result).to be(true)
      expect(repl).to have_received(:puts).with(include("Skein REPL commands"))
    end

    it "handles /status" do
      tasks = instance_double(Skein::Task)
      memory = instance_double(Skein::Memory)
      lessons = instance_double(Skein::Lesson)
      repl.instance_variable_set(:@tasks, tasks)
      repl.instance_variable_set(:@memory, memory)
      repl.instance_variable_set(:@lessons, lessons)
      allow(tasks).to receive(:in_state).and_return([{}, {}])
      allow(memory).to receive(:count).and_return(5)
      allow(memory).to receive(:semantic_enabled?).and_return(true)
      allow(lessons).to receive(:count).and_return(3)
      allow(repl).to receive(:puts)

      result = repl.send(:handle_command, "/status")

      expect(result).to be(true)
      expect(tasks).to have_received(:in_state).with("new", "running", "blocked")
      expect(repl).to have_received(:puts).with(include("Status"))
    end

    it "handles /memories with query" do
      memory = instance_double(Skein::Memory)
      repl.instance_variable_set(:@memory, memory)
      allow(memory).to receive(:search).with(query: "ruby", limit: 10).and_return([])
      allow(repl).to receive(:puts)

      result = repl.send(:handle_command, "/memories ruby")

      expect(result).to be(true)
      expect(memory).to have_received(:search).with(query: "ruby", limit: 10)
    end

    it "handles /memories without query" do
      memory = instance_double(Skein::Memory)
      repl.instance_variable_set(:@memory, memory)
      allow(memory).to receive(:recent).with(limit: 10).and_return([])
      allow(repl).to receive(:puts)

      result = repl.send(:handle_command, "/memories")

      expect(result).to be(true)
      expect(memory).to have_received(:recent).with(limit: 10)
    end

    it "handles /forget-memory with id" do
      memory = instance_double(Skein::Memory)
      repl.instance_variable_set(:@memory, memory)
      allow(memory).to receive(:forget).with(42)
      allow(repl).to receive(:puts)

      result = repl.send(:handle_command, "/forget-memory 42")

      expect(result).to be(true)
      expect(memory).to have_received(:forget).with(42)
    end

    it "handles /forget-memory without id" do
      memory = instance_double(Skein::Memory)
      repl.instance_variable_set(:@memory, memory)
      allow(memory).to receive(:forget)
      allow(repl).to receive(:puts)

      result = repl.send(:handle_command, "/forget-memory")

      expect(result).to be(true)
      expect(memory).not_to have_received(:forget)
      expect(repl).to have_received(:puts).with(include("Usage: /forget-memory"))
    end

    it "handles /maintenance" do
      agent = instance_double(Skein::Agent)
      repl.instance_variable_set(:@agent, agent)
      allow(agent).to receive(:maintenance!)
      allow(repl).to receive(:puts)

      result = repl.send(:handle_command, "/maintenance")

      expect(result).to be(true)
      expect(agent).to have_received(:maintenance!)
    end

    it "handles /summary when no summary exists" do
      db = instance_double(Skein::DB)
      repl.instance_variable_set(:@db, db)
      allow(db).to receive(:get_first_row).and_return(nil)
      allow(repl).to receive(:puts)

      result = repl.send(:handle_command, "/summary")

      expect(result).to be(true)
      expect(repl).to have_received(:puts).with(include("No summary stored"))
    end

    it "handles /summary when a summary exists" do
      db = instance_double(Skein::DB)
      repl.instance_variable_set(:@db, db)
      allow(db).to receive(:get_first_row).and_return(
        {
          "summary" => "User is building Skein",
          "turns_summarized" => 12,
          "updated_at" => "2026-02-24T12:00:00Z",
        }
      )
      allow(repl).to receive(:puts)

      result = repl.send(:handle_command, "/summary")

      expect(result).to be(true)
      expect(repl).to have_received(:puts).with(include("Summary (12 turns summarized)"))
      expect(repl).to have_received(:puts).with("User is building Skein")
    end

    it "handles /reindex-embeddings with default batch size" do
      memory = instance_double(Skein::Memory)
      config = Skein::Config.new(embedding_backfill_batch_size: 33)
      repl.instance_variable_set(:@memory, memory)
      repl.instance_variable_set(:@config, config)
      allow(memory).to receive(:backfill_embeddings).with(batch_size: 33).and_return(2)
      allow(repl).to receive(:puts)

      result = repl.send(:handle_command, "/reindex-embeddings")

      expect(result).to be(true)
      expect(memory).to have_received(:backfill_embeddings).with(batch_size: 33)
    end

    it "handles /reindex-embeddings with explicit batch size" do
      memory = instance_double(Skein::Memory)
      config = Skein::Config.new(embedding_backfill_batch_size: 33)
      repl.instance_variable_set(:@memory, memory)
      repl.instance_variable_set(:@config, config)
      allow(memory).to receive(:backfill_embeddings).with(batch_size: 12).and_return(1)
      allow(repl).to receive(:puts)

      result = repl.send(:handle_command, "/reindex-embeddings 12")

      expect(result).to be(true)
      expect(memory).to have_received(:backfill_embeddings).with(batch_size: 12)
    end

    it "rejects invalid /reindex-embeddings batch sizes" do
      memory = instance_double(Skein::Memory)
      config = Skein::Config.new(embedding_backfill_batch_size: 33)
      repl.instance_variable_set(:@memory, memory)
      repl.instance_variable_set(:@config, config)
      allow(memory).to receive(:backfill_embeddings)
      allow(repl).to receive(:puts)

      result = repl.send(:handle_command, "/reindex-embeddings 0")

      expect(result).to be(true)
      expect(memory).not_to have_received(:backfill_embeddings)
      expect(repl).to have_received(:puts).with(include("Batch size must be > 0"))
    end

    it "handles /new-session" do
      agent = instance_double(Skein::Agent)
      repl.instance_variable_set(:@agent, agent)
      allow(agent).to receive(:clear_session!)
      allow(repl).to receive(:puts)

      result = repl.send(:handle_command, "/new-session")

      expect(result).to be(true)
      expect(agent).to have_received(:clear_session!).with(Skein::Repl::CHAT_ID)
    end

    it "handles /clear-context" do
      agent = instance_double(Skein::Agent)
      repl.instance_variable_set(:@agent, agent)
      allow(agent).to receive(:clear_context!)
      allow(repl).to receive(:puts)

      result = repl.send(:handle_command, "/clear-context")

      expect(result).to be(true)
      expect(agent).to have_received(:clear_context!).with(Skein::Repl::CHAT_ID)
    end

    it "handles /forget-lesson with id" do
      lessons = instance_double(Skein::Lesson)
      repl.instance_variable_set(:@lessons, lessons)
      allow(lessons).to receive(:forget).with(7)
      allow(repl).to receive(:puts)

      result = repl.send(:handle_command, "/forget-lesson 7")

      expect(result).to be(true)
      expect(lessons).to have_received(:forget).with(7)
    end

    it "handles /forget-lesson without id" do
      lessons = instance_double(Skein::Lesson)
      repl.instance_variable_set(:@lessons, lessons)
      allow(lessons).to receive(:forget)
      allow(repl).to receive(:puts)

      result = repl.send(:handle_command, "/forget-lesson")

      expect(result).to be(true)
      expect(lessons).not_to have_received(:forget)
      expect(repl).to have_received(:puts).with(include("Usage: /forget-lesson"))
    end

    it "handles /exit" do
      repl.instance_variable_set(:@running, true)

      result = repl.send(:handle_command, "/exit")

      expect(result).to be(true)
      expect(repl.instance_variable_get(:@running)).to be(false)
    end

    it "handles unknown commands" do
      allow(repl).to receive(:puts)

      result = repl.send(:handle_command, "/wat")

      expect(result).to be(true)
      expect(repl).to have_received(:puts).with(include("Unknown command"))
    end
  end

  describe "#handle_input" do
    it "returns early for slash commands" do
      events = instance_double(Skein::EventStore)
      tasks = instance_double(Skein::Task)
      repl.instance_variable_set(:@events, events)
      repl.instance_variable_set(:@tasks, tasks)
      allow(repl).to receive(:puts)

      expect(events).not_to receive(:append)
      expect(tasks).not_to receive(:create)

      repl.send(:handle_input, "/help")
    end
  end
end
