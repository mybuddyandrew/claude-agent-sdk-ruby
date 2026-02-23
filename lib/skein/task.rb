module Skein
  class Task
    STATES = %w[new waiting_for_input scheduled running blocked completed failed].freeze

    TRANSITIONS = {
      "new"               => %w[running scheduled failed],
      "waiting_for_input" => %w[running failed],
      "scheduled"         => %w[running failed],
      "running"           => %w[completed failed blocked waiting_for_input],
      "blocked"           => %w[running failed],
      "failed"            => %w[new],
    }.freeze

    MUTABLE_ATTRS = %w[result_text requires_approval approved error_message parent_task_id subtask_index].freeze

    class InvalidTransition < StandardError; end

    def initialize(db:, event_store:)
      @db = db
      @event_store = event_store
    end

    def create(source:, chat_id: nil, input_text: nil, lane: 1, parent_task_id: nil, subtask_index: nil)
      @db.execute(
        "INSERT INTO tasks (source, chat_id, input_text, lane, parent_task_id, subtask_index) VALUES (?, ?, ?, ?, ?, ?)",
        [source, chat_id, input_text, lane, parent_task_id, subtask_index]
      )
      id = @db.last_insert_row_id
      @event_store.append(type: "task_created", task_id: id, payload: {
        source: source, chat_id: chat_id, input_text: input_text, lane: lane,
        parent_task_id: parent_task_id, subtask_index: subtask_index
      })
      id
    end

    # Find all subtasks of a parent task, ordered by subtask_index.
    def subtasks(parent_id)
      @db.execute(
        "SELECT * FROM tasks WHERE parent_task_id = ? ORDER BY subtask_index ASC, id ASC",
        [parent_id]
      )
    end

    # Check if all subtasks of a parent are completed.
    def all_subtasks_completed?(parent_id)
      subs = subtasks(parent_id)
      return false if subs.empty?
      subs.all? { |s| s["state"] == "completed" }
    end

    def transition!(task_id, new_state, attrs = {})
      current = find(task_id)
      raise "Task #{task_id} not found" unless current
      current_state = current["state"]

      unless TRANSITIONS.fetch(current_state, []).include?(new_state)
        raise InvalidTransition,
          "Cannot transition task #{task_id} from #{current_state} to #{new_state}"
      end

      set_clauses = ["state = ?", "updated_at = strftime('%Y-%m-%dT%H:%M:%f', 'now')"]
      values = [new_state]

      attrs.each do |col, val|
        col_s = col.to_s
        next unless MUTABLE_ATTRS.include?(col_s)
        set_clauses << "#{col_s} = ?"
        values << val
      end

      values << task_id
      @db.execute(
        "UPDATE tasks SET #{set_clauses.join(', ')} WHERE id = ?",
        values
      )

      @event_store.append(
        type: "task_state_changed",
        task_id: task_id,
        payload: { from: current_state, to: new_state }.merge(attrs)
      )
    end

    def find(task_id)
      @db.get_first_row("SELECT * FROM tasks WHERE id = ?", [task_id])
    end

    # Find the next actionable task: new, no pending subtasks, ordered by lane then id.
    # Optionally filter by lane. Returns a single task hash or nil.
    # Uses a SQL subquery instead of fetching all tasks into Ruby.
    def next_actionable(lane: nil)
      conditions = ["t.state = 'new'"]
      params = []

      if lane
        conditions << "t.lane = ?"
        params << lane
      end

      sql = <<~SQL
        SELECT t.* FROM tasks t
        WHERE #{conditions.join(' AND ')}
          AND NOT EXISTS (
            SELECT 1 FROM tasks sub
            WHERE sub.parent_task_id = t.id
              AND sub.state NOT IN ('completed', 'failed')
          )
        ORDER BY t.lane ASC, t.id ASC
        LIMIT 1
      SQL

      @db.get_first_row(sql, params)
    end

    def in_state(*states)
      placeholders = states.map { "?" }.join(", ")
      @db.execute(
        "SELECT * FROM tasks WHERE state IN (#{placeholders}) ORDER BY lane ASC, id ASC",
        states
      )
    end
  end
end
