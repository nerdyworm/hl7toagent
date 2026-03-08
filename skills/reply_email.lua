return {
  name = "reply_email",
  description = "Send an email reply. Use this to respond to the sender of an incoming email.",
  params = {
    to = { type = "string", required = true, doc = "Recipient email address" },
    subject = { type = "string", required = true, doc = "Email subject line" },
    body = { type = "string", required = true, doc = "Plain text email body" }
  },
  run = function(params)
    return email.send({
      to = params.to,
      subject = params.subject,
      body = params.body
    })
  end
}
