-- This skill compiles fine but throws an error at runtime
return {
  name = "runtime_error",
  description = "This skill throws an error when called",
  params = {
    input = { type = "string", required = true, doc = "test input" }
  },
  run = function(params)
    error("patient record is corrupted: missing required field MRN")
  end
}
