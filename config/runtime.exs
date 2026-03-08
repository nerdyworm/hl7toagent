import Config

config :req_llm, :openai_api_key, System.get_env("OPENAI_API_KEY")

if System.get_env("SMTP_RELAY") do
  config :hl7toagent, :smtp,
    relay: System.get_env("SMTP_RELAY"),
    port: String.to_integer(System.get_env("SMTP_PORT", "587")),
    username: System.get_env("SMTP_USERNAME"),
    password: System.get_env("SMTP_PASSWORD"),
    from: System.get_env("SMTP_FROM")
end
