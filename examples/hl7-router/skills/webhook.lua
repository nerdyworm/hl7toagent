return {
  name = "send_webhook",
  description = "POST JSON data to a webhook URL.",
  params = {
    url = { type = "string", required = true, doc = "The webhook URL to POST to" },
    body = { type = "string", required = true, doc = "The JSON string to send as the request body" }
  },
  run = function(params)
    if not params.url or not params.body then
      return { status = "error", error = "missing url or body" }
    end

    local resp = http.post(params.url, {
      body = params.body,
      headers = { ["Content-Type"] = "application/json" }
    })

    return { status = "ok", http_status = resp.status, response = resp.body }
  end
}
