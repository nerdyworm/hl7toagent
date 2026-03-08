import Config

# Prevent application from trying to start channels in test
config :hl7toagent, :start_channels, false
