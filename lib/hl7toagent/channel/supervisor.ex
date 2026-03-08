defmodule Hl7toagent.Channel.Supervisor do
  use Supervisor

  def start_link(channel_spec) do
    Supervisor.start_link(__MODULE__, channel_spec, name: :"channel_sup_#{channel_spec.name}")
  end

  @impl true
  def init(channel_spec) do
    source_child = source_child_spec(channel_spec)

    children = [
      {Hl7toagent.Channel.Server, channel_spec},
      source_child
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp source_child_spec(%{name: name, source: {:mllp, opts}}) do
    Hl7toagent.Channel.Source.Mllp.child_spec({name, opts})
  end

  defp source_child_spec(%{name: name, source: {:http, opts}}) do
    Hl7toagent.Channel.Source.Http.child_spec({name, opts})
  end

  defp source_child_spec(%{name: name, source: {:file_watcher, opts}}) do
    Hl7toagent.Channel.Source.FileWatcher.child_spec({name, opts})
  end

  defp source_child_spec(%{name: name, source: {:imap, opts}}) do
    Hl7toagent.Channel.Source.Imap.child_spec({name, opts})
  end
end
