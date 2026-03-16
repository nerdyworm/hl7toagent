-- Broken example: skills here are deliberately broken in different
-- ways so you can see what the error messages look like.
--
-- Run with: HL7TOAGENT_PROJECT_DIR=examples/broken mix run --no-halt
-- Then:     curl -X POST http://localhost:4000/test -d "hello"
--
-- NOTE: skills/syntax_error.lua is NOT included here because parse
-- errors crash load_skill! at boot, preventing the channel from
-- starting at all. Try adding it to see that behavior:
--   skills = { "skills/syntax_error.lua", ... }

channel("broken", {
    source = http({ port = 4000, path = "/test" }),
    soul = "souls/tester.md",
    skills = {
        "skills/runtime_error.lua",
        "skills/nil_index.lua",
        "skills/missing_param.lua",
        "skills/ok.lua",
    }
})
