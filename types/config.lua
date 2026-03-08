---@meta

--- Source configuration returned by mllp(), http(), or file_watcher().
---@class Source
---@field type "mllp"|"http"|"file_watcher"|"imap"

--- MLLP source options.
---@class MllpOpts
---@field port integer The TCP port to listen on for HL7 MLLP connections.

--- Create an MLLP source that listens for HL7 messages over TCP.
---@param opts MllpOpts
---@return Source
function mllp(opts) end

--- HTTP source options.
---@class HttpOpts
---@field port integer The TCP port to listen on for HTTP requests.
---@field path? string The URL path to handle (default: "/hl7").

--- Create an HTTP source that receives messages via REST endpoint.
---@param opts HttpOpts
---@return Source
function http(opts) end

--- File watcher source options.
---@class FileWatcherOpts
---@field dir string The directory to watch for new files.
---@field pattern? string Glob pattern to match filenames (default: "*.hl7").
---@field replies? boolean If true, check incoming files for In-Reply-To headers and route replies to the originating channel's thread.

--- Create a file watcher source that triggers on new files in a directory.
---@param opts FileWatcherOpts
---@return Source
function file_watcher(opts) end

--- IMAP source options.
---@class ImapOpts
---@field host string IMAP server hostname.
---@field port? integer IMAP server port (default: 993).
---@field username string IMAP username.
---@field password string IMAP password.
---@field mailbox? string Mailbox to poll (default: "INBOX").
---@field ssl? boolean Use SSL/TLS (default: true).
---@field poll_interval? integer Polling interval in seconds (default: 30).
---@field mark_read? boolean Mark emails as read after processing (default: true).
---@field search? string IMAP search criteria (default: "UNSEEN").

--- Create an IMAP source that polls a mailbox for new emails.
---
--- Example:
--- ```lua
--- channel("email_triage", {
---     source = imap({
---         host = "imap.gmail.com",
---         username = env("IMAP_USERNAME"),
---         password = env("IMAP_PASSWORD"),
---         poll_interval = 60,
---     }),
---     soul = "souls/triage.md",
---     skills = { "builtin:handoff", "builtin:email" },
--- })
--- ```
---@param opts ImapOpts
---@return Source
function imap(opts) end

--- Channel configuration.
---@class ChannelConfig
---@field source Source The message source (from mllp(), http(), file_watcher(), or imap()).
---@field soul string Path to the soul markdown file (system prompt for the LLM).
---@field skills? string[] List of skill paths. Use `"builtin:name"` for built-in skills (email, webhook, log, handoff) or `"skills/foo.lua"` for custom Lua skills.
---@field model? string LLM model override as `"provider:model"` string (e.g. `"openai:gpt-4o"`). Defaults to the system default.

--- Define a channel. Each channel has a source, a soul, and optional skills.
---
--- Example:
--- ```lua
--- channel("adt_router", {
---     source = mllp({ port = 2575 }),
---     soul = "souls/adt_router.md",
---     skills = { "builtin:handoff", "builtin:email", "skills/translate_to_fhir.lua" }
--- })
--- ```
---@param name string Unique name for this channel.
---@param config ChannelConfig
function channel(name, config) end

--- SMTP configuration options.
---@class SmtpOpts
---@field host string SMTP relay hostname.
---@field port? integer SMTP port (default: 587).
---@field username? string SMTP username for authentication.
---@field password? string SMTP password for authentication.
---@field from string Sender email address.
---@field allowed_recipients? string[] Whitelist of allowed recipient email addresses.

--- Configure SMTP settings for email sending.
---
--- Example:
--- ```lua
--- smtp({
---     host = "smtp.gmail.com",
---     port = 587,
---     username = env("SMTP_USERNAME"),
---     password = env("SMTP_PASSWORD"),
---     from = "agent@example.com",
---     allowed_recipients = { "alice@example.com", "bob@example.com" },
--- })
--- ```
---@param opts SmtpOpts
function smtp(opts) end

--- Cron job configuration.
---@class CronConfig
---@field interval integer Polling interval in seconds.
---@field script string Path to a Lua script that produces data. The script's `run()` function is called each interval. Return a string, table, or array of strings/tables to forward to the channel. Return nil to skip.
---@field channel string Name of the target channel to send results to.

--- Define a cron job that polls a data source on an interval.
---
--- The script should return a table with a `run` function:
--- ```lua
--- -- scripts/poll_labs.lua
--- return {
---     run = function()
---         local resp = http.get("https://api.lab.com/results?status=new")
---         if resp.status == 200 then
---             return resp.body
---         end
---         return nil  -- nothing to forward
---     end
--- }
--- ```
---
--- Example:
--- ```lua
--- cron("poll_labs", {
---     interval = 300,
---     script = "scripts/poll_labs.lua",
---     channel = "lab_router",
--- })
--- ```
---@param name string Unique name for this cron job.
---@param config CronConfig
function cron(name, config) end

--- Read an environment variable.
---
--- Example:
--- ```lua
--- local api_key = env("API_KEY")
--- ```
---@param name string Environment variable name.
---@return string? value The value, or nil if not set.
function env(name) end
