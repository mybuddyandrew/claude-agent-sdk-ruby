require "spec_helper"
require "skein/skill"
require "skein/skill_registry"
require "skein/tool_executor"
require "skein/memory"
require "skein/timer"
require "skein/lesson"
require "skein/event_store"
require "tmpdir"
require "fileutils"
require "yaml"

module Skein
  module Skills
    class Greeter < Skein::Skill
      attr_reader :after_task_calls, :maintenance_calls, :schedule_calls

      def initialize(**)
        super
        @after_task_calls = []
        @maintenance_calls = 0
        @schedule_calls = []
      end

      def tools
        [GreeterTool]
      end

      def after_task(task, result)
        @after_task_calls << { task: task, result: result }
      end

      def on_maintenance
        @maintenance_calls += 1
      end

      def on_schedule(timer)
        @schedule_calls << timer
      end
    end

    module GreeterTool
      def self.definition
        {
          name: "greet",
          description: "Say hello to someone",
          input_schema: {
            type: "object",
            properties: {
              name: { type: "string", description: "Name to greet" }
            },
            required: ["name"]
          }
        }
      end

      def self.requires_approval?
        false
      end

      def self.execute(input, **)
        "Hello, #{input['name']}!"
      end
    end
  end
end

RSpec.describe Skein::Skill do
  describe "base defaults" do
    it "has correct defaults" do
      skill = Skein::Skill.new(name: "test", manifest: {})
      expect(skill.name).to eq("test")
      expect(skill.tools).to eq([])
      expect(skill.schedule).to be_nil
      expect(skill.timer_name).to eq("skill:test:schedule")
    end
  end

  describe "context accessors" do
    it "exposes context values" do
      ctx = { memory: :mem, timers: :tim, lessons: :les, events: :evt, db: :db, config: :cfg }
      skill = Skein::Skill.new(name: "test", manifest: {}, context: ctx)
      expect(skill.memory).to eq(:mem)
      expect(skill.timers).to eq(:tim)
      expect(skill.lessons).to eq(:les)
      expect(skill.events).to eq(:evt)
      expect(skill.db).to eq(:db)
      expect(skill.config).to eq(:cfg)
    end
  end

  describe "schedule from manifest" do
    it "reads schedule values" do
      manifest = { "schedule" => { "interval" => 86400, "initial_delay" => 3600 } }
      skill = Skein::Skill.new(name: "daily", manifest: manifest)
      expect(skill.schedule["interval"]).to eq(86400)
      expect(skill.schedule["initial_delay"]).to eq(3600)
    end
  end

  describe "hooks are noop by default" do
    it "does not raise on hook calls" do
      skill = Skein::Skill.new(name: "test", manifest: {})
      skill.after_task({}, "result")
      skill.on_maintenance
      skill.on_schedule({})
    end
  end
end

RSpec.describe Skein::SkillRegistry do
  let(:db) { Skein::DB.new(":memory:") }
  let(:events) { Skein::EventStore.new(db) }
  let(:memory) { Skein::Memory.new(db: db, event_store: events) }
  let(:timers) { Skein::Timer.new(db: db, event_store: events) }
  let(:lessons) { Skein::Lesson.new(db: db, event_store: events) }
  let(:tmpdir) { Dir.mktmpdir("skein-skills-test") }
  let(:context) do
    {
      memory: memory, timers: timers, lessons: lessons,
      events: events, db: db, config: nil,
    }
  end

  after { FileUtils.rm_rf(tmpdir) }

  def create_skill_fixture(name, manifest_yaml, skill_ruby)
    skill_dir = File.join(tmpdir, name)
    FileUtils.mkdir_p(skill_dir)
    File.write(File.join(skill_dir, "manifest.yml"), manifest_yaml)
    File.write(File.join(skill_dir, "skill.rb"), skill_ruby)
  end

  def create_greeter_skill
    create_skill_fixture(
      "greeter",
      "name: greeter\ndescription: A test greeting skill\n",
      "# Greeter class already defined above in Skein::Skills\n"
    )
  end

  describe "#load_all!" do
    it "handles nonexistent skills dir" do
      registry = Skein::SkillRegistry.new(skills_dir: "/nonexistent", context: context)
      registry.load_all!
      expect(registry.skills.size).to eq(0)
    end

    it "handles empty skills dir" do
      registry = Skein::SkillRegistry.new(skills_dir: tmpdir, context: context)
      registry.load_all!
      expect(registry.skills.size).to eq(0)
    end

    it "loads a skill from directory" do
      create_skill_fixture(
        "greeter",
        "name: greeter\ndescription: A test greeting skill\n",
        "# Greeter class already defined above in Skein::Skills\n"
      )
      registry = Skein::SkillRegistry.new(skills_dir: tmpdir, context: context)
      registry.load_all!
      expect(registry.skills.size).to eq(1)
      expect(registry["greeter"]).to be_truthy
      expect(registry["greeter"]).to be_a(Skein::Skills::Greeter)
    end

    it "skips skill with missing skill.rb" do
      skill_dir = File.join(tmpdir, "broken")
      FileUtils.mkdir_p(skill_dir)
      File.write(File.join(skill_dir, "manifest.yml"), "name: broken\n")
      registry = Skein::SkillRegistry.new(skills_dir: tmpdir, context: context)
      registry.load_all!
      expect(registry.skills.size).to eq(0)
    end
  end

  describe "#register_tools!" do
    it "registers skill tools with executor" do
      create_greeter_skill
      registry = Skein::SkillRegistry.new(skills_dir: tmpdir, context: context)
      registry.load_all!
      executor = Skein::ToolExecutor.new(memory: memory, timers: timers)
      defs = registry.register_tools!(executor)
      expect(defs.size).to eq(1)
      expect(defs[0][:name]).to eq("greet")
      expect(executor.known_tool?("skein_greet")).to be_truthy
      expect(executor.requires_approval?("skein_greet")).to be_falsey
      result = executor.execute("skein_greet", { "name" => "World" }, chat_id: "test")
      expect(result).to eq("Hello, World!")
    end
  end

  describe "#run_after_task" do
    it "calls after_task on skills" do
      create_greeter_skill
      registry = Skein::SkillRegistry.new(skills_dir: tmpdir, context: context)
      registry.load_all!
      task = { "id" => "t1", "input_text" => "hello" }
      registry.run_after_task(task, "reply text")
      skill = registry["greeter"]
      expect(skill.after_task_calls.size).to eq(1)
      expect(skill.after_task_calls[0][:result]).to eq("reply text")
    end
  end

  describe "#run_maintenance" do
    it "calls on_maintenance on skills" do
      create_greeter_skill
      registry = Skein::SkillRegistry.new(skills_dir: tmpdir, context: context)
      registry.load_all!
      registry.run_maintenance
      registry.run_maintenance
      expect(registry["greeter"].maintenance_calls).to eq(2)
    end
  end

  describe "hook error handling" do
    it "does not propagate errors from hooks" do
      create_greeter_skill
      registry = Skein::SkillRegistry.new(skills_dir: tmpdir, context: context)
      registry.load_all!
      registry["greeter"].define_singleton_method(:after_task) { |*| raise "boom" }
      registry.run_after_task({}, "test")
    end
  end

  describe "#setup_schedules!" do
    it "creates timers for scheduled skills" do
      create_skill_fixture(
        "scheduled",
        "name: scheduled\ndescription: A scheduled skill\nschedule:\n  interval: 600\n  initial_delay: 60\n",
        "module Skein::Skills\n  class Scheduled < Skein::Skill; end\nend\n"
      )
      registry = Skein::SkillRegistry.new(skills_dir: tmpdir, context: context)
      registry.load_all!
      registry.setup_schedules!
      timer = timers.find_by_name("skill:scheduled:schedule")
      expect(timer).to be_truthy
      expect(timer["interval_seconds"]).to eq(600)
    end

    it "is idempotent" do
      create_skill_fixture(
        "scheduled",
        "name: scheduled\ndescription: A scheduled skill\nschedule:\n  interval: 600\n",
        "module Skein::Skills\n  class Scheduled < Skein::Skill; end\nend unless defined?(Skein::Skills::Scheduled)\n"
      )
      registry = Skein::SkillRegistry.new(skills_dir: tmpdir, context: context)
      registry.load_all!
      registry.setup_schedules!
      registry.setup_schedules!
      all = db.execute("SELECT * FROM timers WHERE name = ?", ["skill:scheduled:schedule"])
      expect(all.size).to eq(1)
    end
  end

  describe "#handle_timer" do
    it "dispatches to the correct skill" do
      create_greeter_skill
      registry = Skein::SkillRegistry.new(skills_dir: tmpdir, context: context)
      registry.load_all!
      timer = { "name" => "skill:greeter:schedule", "payload" => '{"skill":"greeter"}' }
      result = registry.handle_timer(timer)
      expect(result).to be_truthy
      expect(registry["greeter"].schedule_calls.size).to eq(1)
    end

    it "returns false for unknown skill" do
      registry = Skein::SkillRegistry.new(skills_dir: tmpdir, context: context)
      registry.load_all!
      timer = { "name" => "skill:nonexistent:schedule", "payload" => '{"skill":"nonexistent"}' }
      result = registry.handle_timer(timer)
      expect(result).to be_falsey
    end

    it "returns false for non-skill timer" do
      registry = Skein::SkillRegistry.new(skills_dir: tmpdir, context: context)
      timer = { "name" => "heartbeat", "payload" => "{}" }
      result = registry.handle_timer(timer)
      expect(result).to be_falsey
    end
  end
end

RSpec.describe Skein::ToolExecutor, "dynamic tool registration" do
  let(:db) { Skein::DB.new(":memory:") }
  let(:events) { Skein::EventStore.new(db) }
  let(:memory) { Skein::Memory.new(db: db, event_store: events) }
  let(:timers) { Skein::Timer.new(db: db, event_store: events) }
  let(:executor) { Skein::ToolExecutor.new(memory: memory, timers: timers) }

  describe "#register_tool" do
    it "registers a tool" do
      executor.register_tool("skein_greet", Skein::Skills::GreeterTool)
      expect(executor.known_tool?("skein_greet")).to be_truthy
      expect(executor.requires_approval?("skein_greet")).to be_falsey
    end

    it "registers a tool that requires approval" do
      approval_tool = Module.new do
        def self.definition = { name: "dangerous" }
        def self.requires_approval? = true
        def self.execute(input, **) = "done"
      end
      executor.register_tool("skein_dangerous", approval_tool)
      expect(executor.requires_approval?("skein_dangerous")).to be_truthy
    end
  end

  describe "#execute" do
    it "executes a registered tool" do
      executor.register_tool("skein_greet", Skein::Skills::GreeterTool)
      result = executor.execute("skein_greet", { "name" => "Ruby" }, chat_id: "test")
      expect(result).to eq("Hello, Ruby!")
    end
  end

  describe "#registered_tool_names" do
    it "includes builtin and registered tools" do
      initial = executor.registered_tool_names
      expect(initial).to include("skein_remember")
      expect(initial).to include("skein_recall")
      executor.register_tool("skein_greet", Skein::Skills::GreeterTool)
      expect(executor.registered_tool_names).to include("skein_greet")
    end
  end

  describe "builtin tools" do
    it "recognizes all builtin tools" do
      expect(executor.known_tool?("skein_remember")).to be_truthy
      expect(executor.known_tool?("skein_recall")).to be_truthy
      expect(executor.known_tool?("skein_send_telegram")).to be_truthy
      expect(executor.known_tool?("skein_create_reminder")).to be_truthy
      expect(executor.known_tool?("skein_write_note")).to be_truthy
    end
  end
end
