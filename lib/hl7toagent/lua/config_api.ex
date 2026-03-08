defmodule Hl7toagent.Lua.ConfigApi do
  use Lua.API

  @impl Lua.API
  def install(lua, _scope, _data) do
    lua
    |> Lua.put_private(:channels, [])
    |> Lua.put_private(:crons, [])
    |> Lua.put_private(:smtp, nil)
  end

  deflua smtp(opts), state do
    opts = deep_decode(state, opts)
    state = Lua.put_private(state, :smtp, opts)
    {[], state}
  end

  deflua env(name), state do
    {[System.get_env(name) || ""], state}
  end

  deflua mllp(opts), state do
    opts = deep_decode(state, opts)
    {result, state} = Lua.encode!(state, %{"type" => "mllp", "port" => opts["port"]})
    {[result], state}
  end

  deflua http(opts), state do
    opts = deep_decode(state, opts)

    {result, state} =
      Lua.encode!(state, %{
        "type" => "http",
        "port" => opts["port"],
        "path" => opts["path"] || "/hl7"
      })

    {[result], state}
  end

  deflua file_watcher(opts), state do
    opts = deep_decode(state, opts)

    spec = %{
      "type" => "file_watcher",
      "dir" => opts["dir"],
      "pattern" => opts["pattern"] || "*.hl7"
    }

    spec =
      if opts["replies"] do
        Map.put(spec, "replies", true)
      else
        spec
      end

    {result, state} = Lua.encode!(state, spec)
    {[result], state}
  end

  deflua imap(opts), state do
    opts = deep_decode(state, opts)

    {result, state} =
      Lua.encode!(state, %{
        "type" => "imap",
        "host" => opts["host"],
        "port" => opts["port"] || 993,
        "username" => opts["username"],
        "password" => opts["password"],
        "mailbox" => opts["mailbox"] || "INBOX",
        "ssl" => opts["ssl"],
        "poll_interval" => opts["poll_interval"] || 30,
        "mark_read" => opts["mark_read"],
        "search" => opts["search"] || "UNSEEN"
      })

    {[result], state}
  end

  deflua cron(name, config), state do
    config = deep_decode(state, config)

    crons = Lua.get_private!(state, :crons)

    cron_spec = %{
      "name" => name,
      "interval" => config["interval"],
      "script" => config["script"],
      "channel" => config["channel"]
    }

    state = Lua.put_private(state, :crons, [cron_spec | crons])
    {[], state}
  end

  deflua channel(name, config), state do
    config = deep_decode(state, config)
    source = config["source"]
    soul = config["soul"]
    skills = config["skills"] || []
    model = config["model"]

    channels = Lua.get_private!(state, :channels)
    channel_spec = %{"name" => name, "source" => source, "soul" => soul, "skills" => skills, "model" => model}
    state = Lua.put_private(state, :channels, [channel_spec | channels])
    {[], state}
  end

  defp deep_decode(state, {:tref, _} = tref) do
    state
    |> Lua.decode!(tref)
    |> deep_decode_kv(state)
  end

  defp deep_decode(_state, other), do: other

  defp deep_decode_kv(kv_list, state) when is_list(kv_list) do
    # Check if it's an integer-keyed list (array) or string-keyed (map)
    if Enum.all?(kv_list, fn {k, _} -> is_integer(k) end) do
      kv_list
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {_k, v} -> deep_decode(state, v) end)
    else
      Map.new(kv_list, fn {k, v} -> {k, deep_decode(state, v)} end)
    end
  end
end
