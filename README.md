# hl7toagent

Give your HL7 feed a soul.

This started as a vibe-coded idea: what if you replaced the hundreds of lines of field-mapping code in a traditional healthcare integration engine with a markdown file that just *describes what you want* in plain English? Instead of writing HL7-to-JSON transformation logic, you write a system prompt — and an LLM agent figures out the parsing, validation, routing, and edge cases.

It's an experiment in trading deterministic integration code for readable intent. The soul file is something a clinician could review. The skills are tiny Lua scripts that give the agent hands. The whole thing is held together by Elixir supervision trees and an unhealthy amount of optimism.

## Quick start

```bash
mix deps.get
export OPENAI_API_KEY=sk-...

# Start against ./config.lua
mix run --no-halt

# Or point at a separate project directory
HL7TOAGENT_PROJECT_DIR=./my-project mix run --no-halt
```

Or build the binary and use:

```bash
hl7toagent init ./my-project
hl7toagent start ./my-project
```

`OPENAI_API_KEY` is required for both `start` and `init`.

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
4. The agent loops until the work is done (up to 20 tool rounds), stores the conversation in `threads.db`, then returns a final response.

## Examples

### HL7 ADT router — parse, validate, and forward

An MLLP listener that receives HL7 v2 ADT messages, parses them using the LLM, validates clinical safety rules, and POSTs structured JSON to a downstream webhook. The soul file defines the routing rules in plain English — which message types go where, what validation to apply, and what to do with edge cases.

```
my-project/
├── config.lua
├── souls/
│   └── router.md
└── skills/
    ├── webhook.lua
    └── notice.lua
```

**config.lua**
```lua
channel("adt_router", {
    source = mllp({ port = 2575 }),
    soul = "souls/router.md",
    skills = { "skills/webhook.lua", "skills/notice.lua" }
})
```

**souls/router.md**
```markdown
You are a clinical integration engine for ADT messages.

## Routing Rules

- ADT^A04 (Registration): POST to https://ehr.internal/api/patients
- ADT^A01 (Admission): POST to https://ehr.internal/api/admissions
  - Must contain PV1 segment. If missing, still forward but set "warning": true
- ADT^A03 (Discharge): POST to https://ehr.internal/api/discharges
  - Include "disposition": "discharge" in payload

## Validation

PID-3 (Patient Identifier) is required for all patient messages.
Never route a message without a verified patient identifier.
If a message can't be parsed, log a notice — don't guess at field values.
```

**skills/webhook.lua**
```lua
return {
  name = "webhook",
  description = "POST JSON to an external URL",
  params = {
    url  = { type = "string", required = true, doc = "Destination URL" },
    body = { type = "string", required = true, doc = "JSON payload" }
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

The LLM reads the raw HL7, understands the routing rules from the soul, extracts and validates the fields, builds the JSON payload, and calls the webhook skill. No HL7 parsing library needed.

---

### Email agent — receive, reply, and continue the conversation

An IMAP channel that monitors a mailbox, lets an LLM agent respond to emails, and automatically threads replies back into the same conversation. When someone replies to the agent's email, it picks up where it left off.

```
my-project/
├── config.lua
├── souls/
│   └── support.md
└── skills/
    └── reply_email.lua
```

**config.lua**
```lua
smtp({
    host = "smtp.gmail.com",
    port = 587,
    username = env("EMAIL_USER"),
    password = env("EMAIL_PASS"),
    from = env("EMAIL_USER"),
    allowed_recipients = { env("EMAIL_USER") }
})

channel("support", {
    source = imap({
        host = "imap.gmail.com",
        port = 993,
        username = env("EMAIL_USER"),
        password = env("EMAIL_PASS"),
        mailbox = "INBOX",
        poll_interval = 30,
        mark_read = true,
        ssl = true,
        search = 'UNSEEN SUBJECT "[support]"',
    }),
    soul = "souls/support.md",
    skills = { "skills/reply_email.lua" }
})
```

**souls/support.md**
```markdown
You are a support agent for Acme Corp.

When you receive an email, read it carefully and reply with a helpful answer.
If you don't know the answer, say so honestly and offer to escalate.
Keep replies concise and professional.
```

**skills/reply_email.lua**
```lua
return {
  name = "reply_email",
  description = "Send an email reply to the sender",
  params = {
    to      = { type = "string", required = true, doc = "Recipient email" },
    subject = { type = "string", required = true, doc = "Subject line" },
    body    = { type = "string", required = true, doc = "Plain text body" }
  },
  run = function(params)
    return email.send({
      to = params.to,
      subject = params.subject,
      body = params.body
    })
  end
}
```

**What happens:**

1. Someone sends an email with `[support]` in the subject
2. IMAP source picks it up, creates a new thread, feeds it to the agent
3. Agent reads the email, decides to reply, calls `reply_email`
4. The outgoing email gets a `Message-ID` linked to the thread
5. When the person replies, the `In-Reply-To` header matches — the reply is routed back to the same channel and thread
6. The agent sees the full conversation history and continues naturally

No webhook glue, no external thread tracker. Email threading is built in.

---

### HTTP API with multi-step agent logic

An HTTP endpoint that receives data, runs it through multiple tools, and returns a JSON response. The agent decides which tools to call and in what order.

**config.lua**
```lua
channel("lab_api", {
    source = http({ port = 4000, path = "/lab" }),
    soul = "souls/lab_processor.md",
    skills = {
        "skills/translate_to_fhir.lua",
        "skills/webhook.lua",
        "skills/write_log.lua"
    }
})
```

**souls/lab_processor.md**
```markdown
You process lab results (ORU^R01 messages).

For each message:
1. Translate to FHIR R4 format using translate_to_fhir
2. POST the FHIR bundle to https://fhir.internal/Bundle
3. Log the processing result

If any step fails, log the error and continue with remaining steps.
```

POST an HL7 message to `http://localhost:4000/lab` and the agent translates, forwards, logs, and returns a summary — all decided by the LLM based on the soul.

---

### File watcher with email alerts

Watch a directory for new files, process them, and email someone if something looks wrong.

**config.lua**
```lua
smtp({
    host = "smtp.gmail.com",
    port = 587,
    username = env("EMAIL_USER"),
    password = env("EMAIL_PASS"),
    from = env("EMAIL_USER"),
    allowed_recipients = { "oncall@hospital.org" }
})

channel("lab_inbox", {
    source = file_watcher({ dir = "./hl7_drop", pattern = "*.hl7" }),
    soul = "souls/lab_watcher.md",
    skills = { "skills/webhook.lua", "builtin:email" }
})
```

**souls/lab_watcher.md**
```markdown
You monitor incoming HL7 lab result files.

For each file:
1. Parse the HL7 message and extract patient name, test type, and result values
2. POST structured JSON to https://ehr.internal/api/results
3. If any OBX segment has an abnormal flag (H, HH, L, LL, A), email oncall@hospital.org
   with the patient name, test, and abnormal values

Files are automatically archived after processing.
```

Files dropped into `./hl7_drop/` get staged to `processing/`, run through the agent, and archived to `archive/YYYY/MM/DD/`. The agent only emails on abnormal results — that logic lives in the soul, not in code.

---

### Cron polling — pull data on a schedule

Poll an external API and feed results into a channel for processing.

**config.lua**
```lua
channel("results_processor", {
    source = http({ port = 4001, path = "/internal" }),
    soul = "souls/processor.md",
    skills = { "skills/webhook.lua", "skills/write_log.lua" }
})

cron("lab_poller", {
    interval = 60,
    script = "skills/poll_lab.lua",
    channel = "results_processor"
})
```

**skills/poll_lab.lua**
```lua
return {
    run = function()
        local resp = http.get("https://api.lab.com/results?status=new")
        if resp.status == 200 and resp.body ~= "[]" then
            return resp.body   -- forwarded to channel as a message
        end
        return nil             -- nothing new, skip this cycle
    end
}
```

Every 60 seconds, the cron script checks for new results. If there are any, the data is sent to `results_processor` as if it arrived via HTTP — same soul, same skills, same agent loop.

---

### Sub-agent composition — delegate to specialists

A skill can itself be an agent. Give it a `soul` and `skills` instead of a `run` function, and it spawns a nested agent loop. This lets a top-level router delegate to specialist sub-agents.

**config.lua**
```lua
channel("triage", {
    source = http({ port = 4000, path = "/messages" }),
    soul = "souls/triage.md",
    skills = {
        "skills/lab_agent.lua",
        "skills/billing_agent.lua",
        "builtin:log"
    }
})
```

**skills/lab_agent.lua**
```lua
return {
  name = "lab_agent",
  description = "Specialist agent for processing lab/pathology messages",
  soul = "souls/lab_specialist.md",
  skills = { "skills/translate_to_fhir.lua", "skills/webhook.lua" }
}
```

The triage agent decides which specialist to hand off to. The lab agent gets its own soul, its own tools, and runs a full agent loop — then returns the result to the parent. Agents all the way down.

---

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
    skills = { "skills/notice.lua", "skills/webhook.lua" },
    model = "openai:gpt-5-mini"
})

channel("lab_inbox", {
    source = file_watcher({ dir = "./hl7_inbox", pattern = "*.hl7" }),
    soul = "souls/adt_router.md",
    skills = { "skills/translate_to_fhir.lua", "skills/write_log.lua" }
})
```

Config is Lua, not YAML — you get real conditionals, env vars via `env()`, loops, and string manipulation at config time.

Channels also support an optional `model` field if you want to override the default LLM for a specific agent.

### Sources

| Source | Description | Config |
|---|---|---|
| `mllp` | Listens for HL7 v2 messages over the MLLP protocol. Returns proper HL7 ACK/NAK. | `port` |
| `http` | Accepts `POST` requests, stages the request body into `processing/`, and returns JSON. Also exposes `GET /health`. | `port`, `path` |
| `file_watcher` | Monitors a directory for new/modified files matching a glob pattern. Optional reply-routing mode can route email-like replies back to the originating channel thread. | `dir`, `pattern`, `replies` |
| `imap` | Polls an IMAP mailbox for new emails. Supports search filters, SSL, and mark-as-read. | `host`, `port`, `username`, `password`, `mailbox`, `ssl`, `poll_interval`, `mark_read`, `search` |

HTTP sources can continue an existing thread by passing `X-Thread-Id` / `X-Thread-Ref` headers or `thread_id` / `thread_ref` fields in a JSON request body.

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
- `file.write(filename, content)` / `file.read(filename)` / `file.append(filename, content)` / `file.move(src, dest)` / `file.delete(filename)` / `file.list(path)` — sandboxed file operations
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

If the script's `run()` returns data, it gets sent to the target channel as a message. Return `nil` to skip. A cron script can also return a list of messages to forward multiple payloads in one tick.

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

`mix run --no-halt` uses `./config.lua` by default. Set `HL7TOAGENT_PROJECT_DIR=/path/to/project` to run a different project without changing directories.

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

Each incoming message gets a fresh agent loop, but the message history is persisted in `threads.db` so channels can continue prior conversations when they receive a `thread_id` or `thread_ref`. What persists outside that is whatever the skills write to the world: webhook calls, files, emails, and logs.

If you need durable storage, that's what skills are for — write a skill that inserts into a database, pushes to a queue, or calls an API. The agent decides when to use it based on the soul.
