-- HTTP Webhook: receives JSON via HTTP POST, classifies it, and
-- forwards to a downstream webhook. The simplest possible example.

channel("api", {
    source = http({ port = 4000, path = "/incoming" }),
    soul = "souls/classifier.md",
    skills = { "skills/webhook.lua", "builtin:log" }
})
