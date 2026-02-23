module Skein
  class Lane
    L0_INTERRUPT   = 0
    L1_INTERACTIVE = 1

    def initialize(task:)
      @task = task
    end

    # Return the next task to process, respecting lane priority.
    # L0 (interrupt) tasks always preempt L1 (interactive) tasks.
    # Within a lane, tasks are processed in FIFO order.
    # Parent tasks with pending subtasks are skipped.
    def next_task
      @task.next_actionable
    end

    # Return the next L0 task only (for interrupt checking).
    def next_interrupt
      @task.next_actionable(lane: L0_INTERRUPT)
    end

    # Return the next L1 task only (for interactive processing).
    def next_interactive
      @task.next_actionable(lane: L1_INTERACTIVE)
    end

    # Check if there are pending L0 tasks (used by dispatcher to preempt L1).
    def interrupt_pending?
      !next_interrupt.nil?
    end

    def pending_approvals(chat_id: nil)
      blocked = @task.in_state("blocked")
      pending = blocked.select { |t| t["requires_approval"] == 1 && t["approved"].nil? }
      pending = pending.select { |t| t["chat_id"] == chat_id } if chat_id
      pending
    end
  end
end
