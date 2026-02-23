require "yaml"

module Skein
  # Base class for all Skein skills. Subclass this in skills/<name>/skill.rb.
  #
  # Skills can:
  # - Register MCP tools (override `tools`)
  # - Hook into task processing (override `after_task`)
  # - Hook into maintenance (override `on_maintenance`)
  # - Run on a schedule (override `on_schedule`, set schedule in manifest.yml)
  #
  # Skills receive a `context` hash at initialization with core services:
  #   { memory:, timers:, lessons:, events:, db:, config:, logger: }
  #
  class Skill
    attr_reader :name, :manifest, :context

    def initialize(name:, manifest:, context: {})
      @name = name
      @manifest = manifest
      @context = context
    end

    # Override to return an array of tool modules this skill provides.
    # Each module must implement the standard tool interface:
    #   .definition, .requires_approval?, .execute(input, **context)
    def tools
      []
    end

    # Called after a task completes successfully.
    # task: the task hash, result: the bridge result text
    def after_task(task, result)
      # no-op by default
    end

    # Called during periodic maintenance (boot + heartbeat).
    def on_maintenance
      # no-op by default
    end

    # Called when this skill's scheduled timer fires.
    # timer: the timer hash from the DB
    def on_schedule(timer)
      # no-op by default
    end

    # Convenience accessors for common context services
    def memory   = context[:memory]
    def timers   = context[:timers]
    def lessons  = context[:lessons]
    def events   = context[:events]
    def db       = context[:db]
    def config   = context[:config]
    def logger   = context[:logger]

    # Returns the schedule config from manifest, or nil if not scheduled.
    def schedule
      manifest["schedule"]
    end

    # Timer name used for this skill's schedule.
    def timer_name
      "skill:#{name}:schedule"
    end
  end
end
