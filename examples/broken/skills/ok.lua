-- This one actually works — included so you can see the contrast
return {
  name = "ok",
  description = "A working skill that echoes back the input",
  params = {
    input = { type = "string", required = true, doc = "test input" }
  },
  run = function(params)
    return { status = "ok", echo = params.input }
  end
}
