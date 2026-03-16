channel("inbox", {
    source = file_watcher({ dir = "./inbox", pattern = "*" }),
    soul = "souls/inbox.md",
    skills = { "skills/logger.lua", "skills/webhook.lua" }
})
