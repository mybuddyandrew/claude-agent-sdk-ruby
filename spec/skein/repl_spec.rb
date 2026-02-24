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
      allow(repl).to receive(:gets).and_return("yes\n")

      result = repl.request_approval("chat", "Bash", { "command" => "ls" })

      expect(result).to eq("allow")
      expect(repl).to have_received(:start_spinner!)
    end

    it "returns deny for non-yes answers" do
      allow(repl).to receive(:stop_spinner!)
      allow(repl).to receive(:start_spinner!)
      allow(repl).to receive(:puts)
      allow(repl).to receive(:print)
      allow(repl).to receive(:gets).and_return("no\n")

      result = repl.request_approval("chat", "Bash", { "command" => "ls" })

      expect(result).to eq("deny")
      expect(repl).not_to have_received(:start_spinner!)
    end
  end
end
