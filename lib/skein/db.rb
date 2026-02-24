require "sqlite3"
require "json"
require "fileutils"

module Skein
  class DB
    SCHEMA = <<~SQL
      PRAGMA journal_mode = WAL;
      PRAGMA foreign_keys = ON;

      CREATE TABLE IF NOT EXISTS events (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        type        TEXT    NOT NULL,
        task_id     INTEGER,
        payload     TEXT    NOT NULL DEFAULT '{}',
        created_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now')),
        FOREIGN KEY (task_id) REFERENCES tasks(id)
      );

      CREATE INDEX IF NOT EXISTS idx_events_task_id ON events(task_id);
      CREATE INDEX IF NOT EXISTS idx_events_type    ON events(type);
      CREATE INDEX IF NOT EXISTS idx_events_created ON events(created_at);

      CREATE TABLE IF NOT EXISTS tasks (
        id                INTEGER PRIMARY KEY AUTOINCREMENT,
        state             TEXT    NOT NULL DEFAULT 'new',
        lane              INTEGER NOT NULL DEFAULT 1,
        source            TEXT    NOT NULL,
        chat_id           TEXT,
        input_text        TEXT,
        result_text       TEXT,
        requires_approval INTEGER NOT NULL DEFAULT 0,
        approved          INTEGER,
        error_message     TEXT,
        parent_task_id    INTEGER,
        subtask_index     INTEGER,
        created_at        TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now')),
        updated_at        TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now')),
        FOREIGN KEY (parent_task_id) REFERENCES tasks(id)
      );

      CREATE INDEX IF NOT EXISTS idx_tasks_state  ON tasks(state);
      CREATE INDEX IF NOT EXISTS idx_tasks_lane   ON tasks(lane);

      CREATE TABLE IF NOT EXISTS timers (
        id               INTEGER PRIMARY KEY AUTOINCREMENT,
        name             TEXT    NOT NULL UNIQUE,
        interval_seconds INTEGER,
        next_fire_at     TEXT    NOT NULL,
        enabled          INTEGER NOT NULL DEFAULT 1,
        payload          TEXT    NOT NULL DEFAULT '{}',
        created_at       TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
      );

      CREATE INDEX IF NOT EXISTS idx_timers_next_fire ON timers(next_fire_at);
      CREATE INDEX IF NOT EXISTS idx_timers_enabled   ON timers(enabled);

      CREATE TABLE IF NOT EXISTS conversation_turns (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        chat_id    TEXT    NOT NULL,
        role       TEXT    NOT NULL,
        content    TEXT    NOT NULL,
        task_id    INTEGER,
        created_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now')),
        FOREIGN KEY (task_id) REFERENCES tasks(id)
      );

      CREATE INDEX IF NOT EXISTS idx_conv_chat_id ON conversation_turns(chat_id);

      CREATE TABLE IF NOT EXISTS memories (
        id               INTEGER PRIMARY KEY AUTOINCREMENT,
        content          TEXT    NOT NULL,
        category         TEXT,
        source           TEXT    NOT NULL DEFAULT 'extracted',
        source_task_id   INTEGER,
        access_count     INTEGER NOT NULL DEFAULT 0,
        last_accessed_at TEXT,
        created_at       TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
      );

      CREATE INDEX IF NOT EXISTS idx_memories_access_count ON memories(access_count);
      CREATE INDEX IF NOT EXISTS idx_memories_created      ON memories(created_at);

      CREATE TABLE IF NOT EXISTS lessons (
        id               INTEGER PRIMARY KEY AUTOINCREMENT,
        content          TEXT    NOT NULL,
        category         TEXT,
        source_task_id   INTEGER,
        effectiveness    INTEGER NOT NULL DEFAULT 0,
        applied_count    INTEGER NOT NULL DEFAULT 0,
        created_at       TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
      );

      CREATE INDEX IF NOT EXISTS idx_lessons_effectiveness ON lessons(effectiveness);
      CREATE INDEX IF NOT EXISTS idx_lessons_created       ON lessons(created_at);

      CREATE TABLE IF NOT EXISTS sessions (
        chat_id    TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
      );

      CREATE TABLE IF NOT EXISTS conversation_summaries (
        chat_id          TEXT PRIMARY KEY,
        summary          TEXT NOT NULL,
        turns_summarized INTEGER NOT NULL DEFAULT 0,
        updated_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
      );
    SQL

    VECTOR_SCHEMA = <<~SQL
      CREATE VIRTUAL TABLE IF NOT EXISTS memory_embeddings USING vec0(
        memory_id INTEGER PRIMARY KEY,
        embedding float[384]
      );
    SQL

    attr_reader :vec_enabled

    def initialize(path, vec: :auto, busy_timeout_ms: 5000)
      FileUtils.mkdir_p(File.dirname(path)) unless path == ":memory:"
      @db = SQLite3::Database.new(path)
      @db.results_as_hash = true
      @db.busy_timeout = busy_timeout_ms
      @vec_enabled = false
      bootstrap_schema!
      load_vec_extension!(vec)
    end

    def execute(sql, params = [])
      @db.execute(sql, params)
    end

    def get_first_row(sql, params = [])
      @db.get_first_row(sql, params)
    end

    def last_insert_row_id
      @db.last_insert_row_id
    end

    def transaction(&block)
      @db.transaction(&block)
    end

    def close
      @db.close
    end

    private

    def bootstrap_schema!
      @db.execute_batch(SCHEMA)
      run_migrations!
    end

    # Incremental migrations for existing databases.
    # Each migration checks if it's needed before running.
    # This handles the "no migrations system" trade-off from ADR-002.
    def run_migrations!
      # Migration 1: Add parent_task_id and subtask_index to tasks (v2.0 → v2.1)
      unless column_exists?("tasks", "parent_task_id")
        @db.execute("ALTER TABLE tasks ADD COLUMN parent_task_id INTEGER REFERENCES tasks(id)")
        @db.execute("ALTER TABLE tasks ADD COLUMN subtask_index INTEGER")
      end

      # Create indexes that depend on migrated columns
      @db.execute("CREATE INDEX IF NOT EXISTS idx_tasks_parent ON tasks(parent_task_id)")

      # Migration 2: Add sessions table (v2.0 → v2.1)
      # Already handled by CREATE TABLE IF NOT EXISTS in SCHEMA
    end

    def column_exists?(table, column)
      cols = @db.execute("PRAGMA table_info(#{table})")
      cols.any? { |c| c["name"] == column }
    end

    # Load sqlite-vec extension. Modes:
    #   :auto   - try to load, silently degrade if unavailable
    #   true    - require it, raise on failure
    #   false   - skip entirely
    def load_vec_extension!(mode)
      return if mode == false

      begin
        require "sqlite_vec"
        @db.enable_load_extension(true)
        SqliteVec.load(@db)
        @db.enable_load_extension(false)
        @db.execute_batch(VECTOR_SCHEMA)
        @vec_enabled = true
      rescue LoadError, SQLite3::Exception => e
        raise e if mode == true
        # :auto mode — silently degrade
        @vec_enabled = false
      end
    end
  end
end
