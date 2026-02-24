# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Project Overview

This repo ships Skein as the primary runtime and includes two integrated layers:

1. **Skein** (`lib/skein/`) — Personal assistant agent kernel. Handles memory, lessons, task management, tool execution, skill system, conversation summarization, and task decomposition.
2. **Claude Agent SDK compatibility layer** (`lib/claude_agent_sdk/`) — Ruby SDK API retained for existing integrations, wrapping Claude Code CLI stream-JSON subprocess communication.

**Runtime:** Ruby 4.0.0 (via asdf). Claude Code CLI 2.0.0+ at `~/.local/bin/claude` (native binary, uses Max subscription — no API key needed).

**Dependencies:** `async` (~2.0), `mcp` (~0.4), `sqlite3` (~2.9), `sqlite-vec` (~0.1), `informers` (~1.2), `webrick` (~1.9)

## Common Commands

```bash
bundle install                                    # Install dependencies
bundle exec rspec                                 # Run all unit tests (602 examples)
bundle exec rspec spec/unit/                      # SDK specs only (221 examples)
bundle exec rspec spec/skein/                     # Skein specs only (381 examples)
bundle exec rspec spec/skein/agent_spec.rb        # Single spec file
bundle exec rspec spec/skein/agent_spec.rb:42     # Single test by line number
SKEIN_LIVE_TEST=1 bundle exec rspec spec/skein/sdk_live_spec.rb  # Live SDK tests (hits real CLI)
RUN_INTEGRATION=1 bundle exec rspec               # Include SDK integration tests
bundle exec rubocop                               # Run linter
```

## Architecture

### Full Stack

```
Skein Agent Kernel (lib/skein/)
  ├── Agent           ← Core task processing, extraction, summarization
  ├── SdkClient       ← Wraps SDK for task execution, extraction, decomposition
  ├── ToolExecutor    ← Domain tools (remember, recall, send_telegram, etc.)
  ├── SkillRegistry   ← Dynamic skill plugins with hooks and schedules
  ├── Memory/Lesson   ← Persistent knowledge with SQLite + optional vec search
  ├── Task/Timer      ← State machine tasks, recurring/oneshot timers
  ├── Dispatcher/Lane ← Priority-based task scheduling (L0 interrupt, L1 interactive)
  ├── Kernel/REPL     ← Runtime orchestration and interactive CLI
  │
  ▼
Claude Agent SDK (lib/claude_agent_sdk/)
  ├── ClaudeAgentSDK.query()     ← One-shot/streaming queries
  └── ClaudeAgentSDK::Client     ← Bidirectional sessions with hooks/permissions
        │
        ▼
      Query (control protocol, hooks, permissions, MCP routing)
        │
        ▼
      SubprocessCLITransport (Open3.popen3, JSONL stdin/stdout)
        │
        ▼
      Claude Code CLI (~/.local/bin/claude)
```

### SDK Layer (lib/claude_agent_sdk/)

- **`query()`** — Simple function interface for one-shot queries and streaming input via Enumerators.
- **`Client`** — Full bidirectional sessions with hooks, permission callbacks, SDK MCP servers, interrupt, model switching, file rewind.
- **`SubprocessCLITransport`** — Spawns `claude` CLI via `Open3.popen3`, reads newline-delimited JSON.
- **`Query`** — Bidirectional control protocol handler, routes control requests (hooks, permissions, MCP).
- **`SdkMcpServer`** — In-process MCP servers for custom tools (no subprocess needed).
- **`MessageParser`** — Converts raw JSON hashes into typed Ruby objects.

### Skein Layer (lib/skein/)

- **`SdkClient`** (~350 lines) — Wraps `ClaudeAgentSDK::Client` for task execution and `ClaudeAgentSDK.query()` for extraction/decomposition. Builds MCP tools from ToolExecutor registry each task. Handles `can_use_tool` permission callback.
- **`Agent`** (~580 lines) — Core task processor. Handles decomposition, extraction (lessons/memories), conversation summarization, memory consolidation, session persistence, subtask lifecycle.
- **`ToolExecutor`** (~90 lines) — Mutable tool registry with `register_tool()`. Built-in tools: remember, recall, send_telegram, create_reminder, write_note.
- **`Memory`** (~220 lines) — SQLite-backed memory store with keyword search, optional semantic search via embeddings. Deduplication, access counting, format_for_prompt.
- **`Lesson`** (~120 lines) — Behavioral lessons with effectiveness scoring, pruning, rate_for_task.
- **`Task`** (~135 lines) — State machine (new → running → completed/failed/blocked). Subtask support with parent completion tracking.
- **`Skill`/`SkillRegistry`** — Plugin system. Skills live in `skills/<name>/` with `manifest.yml` + `skill.rb`. Hooks: `after_task`, `on_maintenance`, `on_schedule`. Dynamic tool registration.
- **`DB`** (~200 lines) — SQLite3 with 9 tables, optional sqlite-vec for embeddings. Schema: events, tasks, timers, conversation_turns, memories, lessons, memory_embeddings, sessions, conversation_summaries.
- **`Dispatcher`/`Lane`** — Priority-based task scheduling. L0 (interrupt) preempts L1 (interactive).
- **`Config`** (~135 lines) — ENV-based config with constructor overrides. Auto-approve rules, embedding config, notes dir.

### How SdkClient Uses the SDK

SdkClient creates a fresh `ClaudeAgentSDK::Client` per task with:
- MCP server built from ToolExecutor's registry (tools execute in-process)
- `can_use_tool` lambda for permission routing (safe builtins auto-allow, others route to channel)
- `permission_mode: "bypassPermissions"` (permissions handled by callback)
- `include_partial_messages: true` for streaming
- Session resumption via `resume: session_id`

For extraction/decomposition, it uses `ClaudeAgentSDK.query()` with `output_format: { type: "json_schema", schema: ... }` for structured output.

### DB Schema (9 tables)

`events`, `tasks`, `timers`, `conversation_turns`, `memories`, `lessons`, `memory_embeddings`, `sessions`, `conversation_summaries`

## Key Conventions

### SDK Layer
- All source in `lib/claude_agent_sdk/`, entry point is `lib/claude_agent_sdk.rb`
- Types use plain Ruby classes with `attr_accessor` and keyword args (no Struct/Data)
- Hook inputs are typed classes inheriting from `BaseHookInput`
- `to_h` methods convert Ruby snake_case to CLI camelCase
- `ClaudeAgentOptions` is the central config object (~30 fields)

### Skein Layer
- All source in `lib/skein/`, entry point is `lib/skein.rb`
- SQLite3 for persistence, in-memory `:memory:` for tests
- Domain tools are modules with `.definition`, `.requires_approval?`, `.execute(input, **)`
- Skills are classes inheriting from `Skein::Skill` with hooks
- `SdkClient::SdkError` is the unified error type
- Ruby 4.0 specifics: `SQLite3::Database#execute` returns frozen arrays (use `sort_by` not `sort_by!`)

### Testing
- RSpec with `expect` syntax only, `disable_monkey_patching!` enabled
- SDK test helpers in `spec/support/test_helpers.rb`
- Skein test helpers in `spec/support/skein_helpers.rb` (`create_test_db`)
- Live tests gated behind `SKEIN_LIVE_TEST=1` (hit real Claude CLI)
- Agent tests use `MockSdkClient` (defined in `spec/skein/agent_spec.rb`)
- RuboCop config: max line length 120, max method length 30, Style/Documentation disabled
