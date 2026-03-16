-- HL7 Router: receives HL7 v2 messages over MLLP and routes them
-- by message type. Also exposes an HTTP endpoint for testing.

channel("mllp_intake", {
    source = mllp({ port = 2575 }),
    soul = "souls/router.md",
    skills = { "skills/translate_to_fhir.lua", "skills/webhook.lua", "skills/write_log.lua" }
})

channel("http_intake", {
    source = http({ port = 4000, path = "/hl7" }),
    soul = "souls/router.md",
    skills = { "skills/translate_to_fhir.lua", "skills/webhook.lua", "skills/write_log.lua" }
})
