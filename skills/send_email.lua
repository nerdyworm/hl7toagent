return {
  name = "send_email",
  description = "Sends an email to a recipient via SMTP. The email is automatically linked to the current conversation thread so that replies can be routed back.",
  params = {
    to = { type = "string", required = true, doc = "Email address of the recipient" },
    subject = { type = "string", required = true, doc = "Email subject line" },
    body = { type = "string", required = true, doc = "Plain text email body" }
  },
  run = function(params)
    if not params.to or params.to == "" then
      return { status = "error", reason = "to is required" }
    end
    if not params.subject or params.subject == "" then
      return { status = "error", reason = "subject is required" }
    end

    local result = email.send({
      to = params.to,
      subject = params.subject,
      body = params.body or ""
    })

    return result
  end
}
