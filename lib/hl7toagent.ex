defmodule Hl7toagent do
  @moduledoc """
  Lua driven integration engine with AI agents.
  """

  def process(channel_name, raw_data) do
    Hl7toagent.Channel.Server.process_message(channel_name, raw_data)
  end

  def load_config(path \\ "./config.lua") do
    {channels, crons} = Hl7toagent.ConfigLoader.load_config!(path)
    %{channels: channels, crons: crons}
  end
end
