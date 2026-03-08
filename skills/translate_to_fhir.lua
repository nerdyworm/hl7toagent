return {
  name = "translate_to_fhir",
  description = "Translates an HL7 v2 message to FHIR R4 JSON format",
  run = function(params)
    -- For now, return a stub FHIR bundle.
    -- In production, this would call an external FHIR converter.
    return {
      resourceType = "Bundle",
      type = "transaction",
      entry = {},
      meta = {
        source = "hl7toagent",
        originalMessage = params.message
      }
    }
  end
}
