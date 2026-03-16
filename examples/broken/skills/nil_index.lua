-- This skill tries to index a nil value
return {
  name = "nil_index",
  description = "This skill crashes by accessing a field on nil",
  params = {
    input = { type = "string", required = true, doc = "test input" }
  },
  run = function(params)
    local patient = nil
    return { name = patient.name, mrn = patient.mrn }
  end
}
