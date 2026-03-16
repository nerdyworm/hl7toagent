-- This skill has a Lua syntax error (unclosed table)
return {
  name = "syntax_error",
  description = "This skill has a syntax error and will fail to load",
  params = {
    input = { type = "string", required = true, doc = "test input" }
  },
  run = function(params)
    local x = {
    return x
  end
}
