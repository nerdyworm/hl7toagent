return {
  name = "send_webhook",
  description = "POST JSON data to a webhook URL.",
  params = {
    url = { type = "string", required = true, doc = "The webhook URL to POST to" },
    body = { type = "string", required = true, doc = "The JSON string to send as the request body" }
  },
  run = function(params)
    local url = params.url
    local body = params.body
    if not url or not body then
      return { status = "error", error = "missing url or body" }
    end

    local resp = http.post(url, {
      body = body,
      headers = { ["Content-Type"] = "application/json" }
    })

    return { status = "ok", http_status = resp.status, response = resp.body }
  end
}
