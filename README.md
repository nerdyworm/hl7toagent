# hl7toagent

Give your HL7 feed a soul.

This started as a vibe-coded idea: what if you replaced the hundreds of lines of field-mapping code in a traditional healthcare integration engine with a markdown file that just *describes what you want* in plain English? Instead of writing HL7-to-JSON transformation logic, you write a system prompt — and an LLM agent figures out the parsing, validation, routing, and edge cases.

It's an experiment in trading deterministic integration code for readable intent. The soul file is something a clinician could review. The skills are tiny Lua scripts that give the agent hands. The whole thing is held together by Elixir supervision trees and an unhealthy amount of optimism.

## How it works

```
             ┌─────────────────────────────────────┐
  HL7/data   │            Channel                  │
 ──────────► │  Source ─► Agent Loop ─► Skills      │ ──► webhooks, files, APIs
             │           (soul.md)    (Lua scripts) │
             └─────────────────────────────────────┘
```

1. A **source** receives data — an MLLP HL7 feed, an HTTP POST, a new file in a directory, or an email via IMAP.
2. The raw data is handed to the channel's **agent loop**, which calls an LLM with the channel's **soul** (a markdown system prompt) and the incoming message.
3. The LLM decides which **skills** to call — Lua scripts that can hit webhooks, write files, translate formats, send emails, or anything else you wire up.
4. The agent loops until the work is done (up to 20 tool rounds), then returns a final response.

## Configuration

Everything is defined in `config.lua`:

```lua
channel("adt_router", {
    source = mllp({ port = 2575 }),
    soul = "souls/adt_router.md",
    skills = { "skills/translate_to_fhir.lua", "skills/write_log.lua" }
})

channel("api", {
    source = http({ port = 4000, path = "/hl7" }),
    soul = "souls/router.md",
    skills = { "skills/notice.lua", "skills/webhook.lua" }
})

channel("lab_inbox", {
    source = file_watcher({ dir = "./hl7_inbox", pattern = "*.hl7" }),
    soul = "souls/adt_router.md",
    skills = { "skills/translate_to_fhir.lua", "skills/write_log.lua" }
})
```

Config is Lua, not YAML — you get real conditionals, env vars via `env()`, loops, and string manipulation at config time.

### Sources

| Source | Description | Config |
|---|---|---|
| `mllp` | Listens for HL7 v2 messages over the MLLP protocol. Returns proper HL7 ACK/NAK. | `port` |
| `http` | Accepts POST requests with raw message bodies. Returns JSON responses. | `port`, `path` |
| `file_watcher` | Monitors a directory for new/modified files matching a glob pattern. | `dir`, `pattern` |
| `imap` | Polls an IMAP mailbox for new emails. Supports search filters and mark-as-read. | `host`, `port`, `username`, `password`, `mailbox`, `poll_interval`, `search` |

### Souls

A soul is a markdown file that becomes the agent's system prompt. It tells the agent what it is, what rules to follow, and how to handle different message types. This is where your routing logic, validation rules, and transformation specs live — in plain English instead of code.

### Skills

A skill is a Lua script that returns a table with `name`, `description`, and a `run` function. Skills are registered as tools the LLM can call.

```lua
return {
  name = "webhook",
  description = "Sends an HTTP POST to a URL with a JSON body",
  params = {
    url  = { type = "string", required = true, doc = "Destination URL" },
    body = { type = "string", required = true, doc = "JSON string to send" }
  },
  run = function(params)
    local resp = http.post(params.url, {
      headers = { ["Content-Type"] = "application/json" },
      body = params.body
    })
    return { status = "ok", http_status = resp.status }
  end
}
```

Skills have access to built-in Lua APIs:
- `http.get(url, opts)` / `http.post(url, opts)` / `http.put(url, opts)` / `http.delete(url, opts)` — make HTTP requests
- `file.write(filename, content)` / `file.read(filename)` / `file.delete(filename)` / `file.list(pattern)` — sandboxed file operations
- `email.send({ to, subject, body })` — send email (requires `smtp()` in config)

#### Sub-agent skills

A skill can itself be an agent. Add a `soul` field (path to a markdown prompt) and a `skills` list (paths to other Lua skill scripts), and the skill spawns a nested agent loop instead of running a Lua function. This lets you compose agent hierarchies — a top-level router agent that delegates to specialist sub-agents.

#### Builtin skills

Reference these as `"builtin:name"` in your skills list:

| Skill | What it does |
|---|---|
| `builtin:email` | Send email via SMTP. Requires `smtp()` config with `allowed_recipients`. |
| `builtin:webhook` | HTTP requests to external URLs (GET/POST/PUT/DELETE). |
| `builtin:log` | Write structured log entries at info/warning/error levels. |
| `builtin:handoff` | Route a message to another channel, with optional thread continuity. |

### Cron jobs

Cron jobs run Lua scripts on an interval and feed results into a channel:

```lua
cron("lab_poller", {
    interval = 60,              -- seconds
    script = "skills/poll.lua", -- must return a table with run()
    channel = "lab_inbox",      -- target channel name
})
```

If the script's `run()` returns data, it gets sent to the target channel as a message. Return `nil` to skip.

### Email threading

Channels can send emails and continue the conversation when the recipient replies. The system tracks threads via `Message-ID` / `In-Reply-To` headers and a SQLite store (`threads.db`). When a reply arrives via IMAP, it's routed back to the original channel and thread automatically.

## CLI

The binary has two commands:

### `hl7toagent init [dir]`

Interactive project scaffolder. An LLM agent walks you through setting up a new project — asks what data you're receiving, what should happen with it, and writes the config, souls, and skills files for you. The scaffolder eats its own dogfood.

```bash
$ hl7toagent init ./my-project

hl7toagent project setup
========================

What kind of data are you receiving? ...
```

### `hl7toagent start [dir]`

Start processing. All channels defined in `config.lua` start automatically, each in its own supervised process tree.

```bash
$ export OPENAI_API_KEY=sk-...
$ hl7toagent start ./my-project
```

## Running from source

```bash
# Install dependencies
mix deps.get

# Set your LLM API key
export OPENAI_API_KEY=sk-...

# Start all channels (uses config.lua in cwd, or set HL7TOAGENT_PROJECT_DIR)
mix run --no-halt

# Run tests
mix test
```

## Building the binary

hl7toagent uses [Burrito](https://github.com/burrito-elixir/burrito) to produce standalone binaries. No Erlang or Elixir installation required on the target machine.

```bash
# Build for all targets (linux x86_64, macOS x86_64, macOS ARM)
MIX_ENV=prod mix release

# Build outputs land in burrito_out/
# e.g. burrito_out/hl7toagent_linux, hl7toagent_macos, hl7toagent_macos_arm
```

Targets are configured in `mix.exs` under `releases`:
- `linux` — x86_64
- `macos` — x86_64
- `macos_arm` — Apple Silicon (aarch64)

## Project structure

```
config.lua              # Channel and cron definitions
souls/                  # System prompts (markdown)
skills/                 # Tool scripts (Lua)
threads.db              # Conversation thread store (auto-created)
processing/             # Transient staging area (auto-created)
archive/YYYY/MM/DD/     # Processed files (auto-created)
```

## Where data goes

hl7toagent is stateless between messages. Each incoming message gets a fresh agent loop — no conversation history unless you're using threads. What persists is whatever the skills write to the outside world: webhook calls, files, emails. The `threads.db` SQLite database tracks email conversation threads for reply continuity.

If you need durable storage, that's what skills are for — write a skill that inserts into a database, pushes to a queue, or calls an API. The agent decides when to use it based on the soul.
