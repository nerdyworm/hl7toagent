# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
mix deps.get              # install dependencies
mix compile               # compile
mix run --no-halt         # start all channels (requires config.lua in cwd)
mix test                  # run tests
mix test test/some_test.exs:42  # run a single test by file:line

# Environment
export OPENAI_API_KEY=sk-...   # required — set in config/runtime.exs via req_llm

# Burrito release (cross-platform binary)
MIX_ENV=prod mix release
```

The binary supports `hl7toagent init [dir]` (interactive LLM-guided project scaffolder) and `hl7toagent start [dir]`. When running via `mix run --no-halt`, the project dir defaults to cwd (override with `HL7TOAGENT_PROJECT_DIR`).

## Architecture

Lua-config-driven channel engine. Each channel is an LLM agent backed by a markdown system prompt ("soul") and Lua tool scripts ("skills").

### Data flow

```
Source (MLLP/HTTP/FileWatcher/IMAP)
  → Pipeline.stage (deterministic file lifecycle: inbox → processing → archive)
  → Channel.Server (GenServer, builds LLM context from soul + incoming message)
  → AgentLoop.run (recursive tool loop, up to 20 rounds)
    → LLM decides which skills to call
    → Skills execute (Lua VM with sandboxed file/http APIs)
  → Pipeline.archive
  → Response back to source (MLLP ACK, HTTP JSON, or silent for file_watcher)

Cron.Runner (interval-based Lua script)
  → Executes script's run() function
  → Forwards non-nil results to target channel via process_message
```

### Supervision tree

```
Supervisor (one_for_one)
├── Registry (Hl7toagent.ChannelRegistry)
├── ThreadStore (SQLite — threads.db)
├── Channel.Supervisor per channel (rest_for_one)
│   ├── Channel.Server (GenServer — holds soul, tools, runs AgentLoop)
│   └── Source adapter (MLLP.Receiver / Bandit / FileWatcher / IMAP)
└── Cron.Runner per cron job (interval-based Lua script → channel)
```

`rest_for_one` ordering matters: Server must start before Source so the source can send messages to it.

### Key modules

- **ConfigLoader** — Evaluates `config.lua` in a Lua VM with ConfigApi loaded. The Lua functions `channel()`, `cron()`, `mllp()`, `http()`, `file_watcher()`, `imap()` are `deflua` macros that accumulate specs in Lua private state. Returns `{channels, crons}` tuple.
- **Channel.Server** — GenServer per channel. On `{:process, raw_data}`, builds `[system(soul), user(message)]` context and calls `AgentLoop.run/3`.
- **AgentLoop** — Reusable LLM tool loop shared by Server (top-level) and Skill (sub-agents). Calls `ReqLLM.generate_text/3`, checks for tool calls, executes them, appends results, loops. Stateless — each message gets a fresh context.
- **Channel.Skill** — Loads a Lua skill file. If the skill has a `soul` field, it becomes a **sub-agent** (spawns a nested AgentLoop); otherwise it's a plain **tool** (executes Lua `run` function). This enables composable agent hierarchies.
- **Pipeline** — Deterministic file lifecycle (stage → process → archive). No LLM involvement in file movement.
- **Source adapters** — MLLP dynamically creates a dispatcher module per channel via `Module.create/3`. HTTP uses Bandit+Plug. FileWatcher uses the `file_system` library.

### Lua integration patterns

- `deflua` args arrive as `{:tref, N}` tuples. Always `Lua.decode!/2` then `Lua.Table.deep_cast/1`.
- Nested trefs need recursive decoding — see `ConfigApi.deep_decode/2` and `Skill.deep_decode/2`.
- Lua APIs are scoped modules (`use Lua.API, scope: "http"` → exposes `http.get`, `http.post` etc. in Lua).
- FileApi enforces path sandboxing via `resolve_safe_path!/2` — all file operations are constrained to the project directory.
- HttpApi passes through to `Req` — no URL allowlisting currently.

### Project structure (user-facing)

A deployed hl7toagent project directory contains:
- `config.lua` — channel and cron definitions using `channel()`, `cron()`, `mllp()`, `http()`, `file_watcher()`, `imap()`
- `souls/*.md` — system prompts (plain markdown, becomes the LLM system message)
- `skills/*.lua` — tool scripts returning `{name, description, params, run}` tables
- `processing/` — transient staging area (auto-created)
- `archive/YYYY/MM/DD/` — processed files (auto-created)

### LLM provider

Model hardcoded as `"openai:gpt-5-mini"` in both `Channel.Server` and `AgentLoop` (`@default_model`). Uses `req_llm` for all LLM calls — provider-agnostic, model specified as `"provider:model"` string.

### Skill file format

```lua
return {
  name = "skill_name",
  description = "LLM reads this to decide when to call it",
  params = {
    param_name = { type = "string", required = true, doc = "Description" }
  },
  run = function(params)
    -- has access to: http.get/post/put/delete, file.read/write/delete/move/list
    return { status = "ok" }
  end
}
```

If `params` is omitted, defaults to a single `message` string parameter. A skill with a `soul` and `skills` field becomes a sub-agent instead of calling `run`.
