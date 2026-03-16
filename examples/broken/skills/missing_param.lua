-- This skill expects a param that won't be provided, then does
-- something unsafe with the nil value
return {
  name = "missing_param",
  description = "This skill concatenates a required field that may be nil",
  params = {
    patient_id = { type = "string", required = true, doc = "patient MRN" }
  },
  run = function(params)
    local filename = "patients/" .. params.patient_id .. ".json"
    return file.read(filename)
  end
}
