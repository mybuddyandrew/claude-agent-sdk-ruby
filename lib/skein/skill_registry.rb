require "yaml"

module Skein
  # Discovers, loads, and manages skills from the skills/ directory.
  #
  # Each skill lives in skills/<name>/ with:
  #   manifest.yml  — metadata, description, schedule config
  #   skill.rb      — Ruby class extending Skein::Skill
  #
  # Usage:
  #   registry = SkillRegistry.new(skills_dir: "skills", context: { memory:, timers:, ... })
  #   registry.load_all!
  #   registry.register_tools!(tool_executor)
  #   registry.setup_schedules!
  #
  class SkillRegistry
    attr_reader :skills, :skills_dir

    def initialize(skills_dir: "skills", context: {}, logger: nil)
      @skills_dir = skills_dir
      @context = context
      @logger = logger
      @skills = {}  # name => Skill instance
    end

    # Discover and load all skills from skills_dir.
    # Silently skips skills that fail to load.
    def load_all!
      return unless Dir.exist?(@skills_dir)

      Dir.glob(File.join(@skills_dir, "*", "manifest.yml")).each do |manifest_path|
        load_skill(manifest_path)
      end

      log("Loaded #{@skills.size} skill(s): #{@skills.keys.join(', ')}") if @skills.any?
    end

    # Register all skill tools with the ToolExecutor.
    # Returns an array of tool definitions (for bridge registration).
    def register_tools!(tool_executor)
      definitions = []

      @skills.each_value do |skill|
        skill.tools.each do |tool_mod|
          defn = tool_mod.definition
          tool_name = "skein_#{defn[:name]}"
          tool_executor.register_tool(tool_name, tool_mod)
          definitions << defn
          log("Registered tool #{tool_name} from skill #{skill.name}")
        end
      end

      definitions
    end

    # Create timers for skills that define a schedule in their manifest.
    def setup_schedules!
      timers = @context[:timers]
      return unless timers

      @skills.each_value do |skill|
        sched = skill.schedule
        next unless sched

        # Don't recreate if the timer already exists
        existing = timers.find_by_name(skill.timer_name)
        next if existing

        initial_delay = (sched["initial_delay"] || sched["interval"] || 3600).to_i
        interval = sched["interval"]&.to_i

        timers.create(
          name: skill.timer_name,
          next_fire_at: Time.now.utc + initial_delay,
          interval_seconds: interval,
          payload: { "skill" => skill.name }
        )
        log("Scheduled #{skill.timer_name} (interval: #{interval}s)")
      end
    end

    # Dispatch a skill timer fire to the correct skill.
    # Returns true if handled, false if skill not found.
    def handle_timer(timer)
      payload = timer["payload"]
      payload = JSON.parse(payload) if payload.is_a?(String)
      skill_name = payload&.dig("skill")
      return false unless skill_name

      skill = @skills[skill_name]
      unless skill
        log("Warning: timer for unknown skill '#{skill_name}'")
        return false
      end

      skill.on_schedule(timer)
      true
    rescue => e
      log("Error in skill #{skill_name} on_schedule: #{e.message}")
      false
    end

    # Run after_task hooks for all skills.
    def run_after_task(task, result)
      @skills.each_value do |skill|
        skill.after_task(task, result)
      rescue => e
        log("Error in skill #{skill.name} after_task: #{e.message}")
      end
    end

    # Run on_maintenance hooks for all skills.
    def run_maintenance
      @skills.each_value do |skill|
        skill.on_maintenance
      rescue => e
        log("Error in skill #{skill.name} on_maintenance: #{e.message}")
      end
    end

    # Get a skill by name.
    def [](name)
      @skills[name]
    end

    private

    def load_skill(manifest_path)
      skill_dir = File.dirname(manifest_path)
      skill_file = File.join(skill_dir, "skill.rb")
      name = File.basename(skill_dir)

      unless File.exist?(skill_file)
        log("Warning: skill #{name} has manifest but no skill.rb, skipping")
        return
      end

      manifest = YAML.safe_load(File.read(manifest_path)) || {}

      # Load the skill Ruby file. It should define a class that extends Skein::Skill.
      require(File.expand_path(skill_file))

      # Find the skill class — convention: CamelCase version of the directory name.
      class_name = name.split(/[-_]/).map(&:capitalize).join
      klass = find_skill_class(class_name)

      unless klass
        log("Warning: skill #{name} loaded but no class #{class_name} found, skipping")
        return
      end

      skill = klass.new(name: name, manifest: manifest, context: @context)
      @skills[name] = skill
    rescue => e
      log("Error loading skill #{name}: #{e.message}")
    end

    def find_skill_class(class_name)
      # Look in Skein::Skills::<ClassName> first, then top-level
      if Skein.const_defined?(:Skills) && Skein::Skills.const_defined?(class_name)
        Skein::Skills.const_get(class_name)
      elsif Object.const_defined?(class_name)
        Object.const_get(class_name)
      end
    end

    def log(msg)
      if @logger
        @logger.call("[SkillRegistry] #{msg}")
      end
    end
  end
end
