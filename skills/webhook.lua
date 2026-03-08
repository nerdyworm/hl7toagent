return {
  name = "webhook",
  description = "Sends an HTTP POST request to a URL with a JSON body. Use this to deliver payloads to webhooks, APIs, or external services.",
  params = {
    url = { type = "string", required = true, doc = "The destination URL to POST to" },
    body = { type = "string", required = true, doc = "The JSON string to send as the request body" }
  },
  run = function(params)
    local url = params.url
    local body = params.body

    if not url or url == "" then
      return { status = "error", reason = "url is required" }
    end
    if not body or body == "" then
      return { status = "error", reason = "body is required" }
    end

    local resp = http.post(url, {
      headers = { ["Content-Type"] = "application/json" },
      body = body
    })

    return {
      status = "ok",
      http_status = resp.status,
      response_body = resp.body
    }
  end
}
