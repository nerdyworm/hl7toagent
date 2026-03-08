smtp({
    host = "smtp.gmail.com",
    port = 587,
    username = env("IMAP_USERNAME"),
    password = env("IMAP_PASSWORD"),
    from = env("SMTP_FROM"),
    allowed_recipients = {
        env("SMTP_FROM"),
    }
})

channel("adt_router", {
    source = mllp({ port = 2575 }),
    soul = "souls/adt_router.md",
    model = "openai:gpt-5-mini",
    skills = { "skills/translate_to_fhir.lua", "skills/write_log.lua" }
})

channel("api", {
    source = http({ port = 4000, path = "/hl7" }),
    soul = "souls/adt_router.md",
    skills = { "skills/translate_to_fhir.lua", "skills/write_log.lua" }
})

channel("api_v2", {
    source = http({ port = 4200, path = "/hl7/v2" }),
    soul = "souls/router.md",
    model = "openai:gpt-5",
    skills = { "skills/notice.lua", "skills/webhook.lua", "skills/send_email.lua" }
})

channel("inbox", {
    source = file_watcher({ dir = "./sandbox/inbox", pattern = "*" }),
    soul = "souls/adt_router.md",
    skills = { "builtin:email" }
})

-- channel("email_replies", {
--     source = file_watcher({ dir = "./replies", pattern = "*.eml", replies = true }),
--     soul = "souls/router.md",
--     model = "openai:gpt-5",
--     skills = { "skills/notice.lua", "skills/webhook.lua", "skills/send_email.lua" }
-- })

local username = env("IMAP_USERNAME")
local password = env("IMAP_PASSWORD")

if username ~= "" and password ~= "" then
    channel("email_inbox", {
        source = imap({
            host = "imap.gmail.com",
            port = 993,
            username = username,
            password = password,
            mailbox = "INBOX",
            poll_interval = 30,
            mark_read = true,
            ssl = true,
            search = 'UNSEEN SUBJECT "[inbox]"',
        }),
        soul = "souls/email.md",
        skills = { "skills/reply_email.lua" }
    })
end

cron("poller", {
    interval = 30,
    script = "skills/poll.lua",
    channel = "inbox",
})
