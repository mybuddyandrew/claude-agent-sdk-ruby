module Skein
  module Dispatcher
    # Sequential dispatcher: processes one task at a time in the main thread.
    # L0 tasks preempt L1 — if an L0 task is available, it's processed first.
    # This is the default and always-safe dispatcher.
    class Sequential
      attr_reader :lane, :tasks, :agent

      def initialize(lane:, tasks:, agent:, logger: nil)
        @lane   = lane
        @tasks  = tasks
        @agent  = agent
        @logger = logger || ->(msg) { $stdout.puts "[Dispatcher] #{msg}" }
      end

      # Process the next available task, respecting lane priority.
      # Returns true if a task was processed, false if idle.
      def tick
        task = @lane.next_task
        return false unless task

        @tasks.transition!(task["id"], "running")
        @agent.process_task(task)
        true
      end

      # No-op for sequential dispatcher (no workers to stop).
      def shutdown
      end

      # Sequential dispatcher is never busy with a background task.
      def busy?(_lane_id = nil)
        false
      end
    end
  end
end
