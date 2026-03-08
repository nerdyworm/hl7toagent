defmodule Hl7toagent.ConfigLoader do
  @moduledoc """
  Loads channel configuration from a Lua config file.
  """

  def load_config!(path, project_dir \\ nil) do
    project_dir = project_dir || Application.get_env(:hl7toagent, :project_dir, File.cwd!())

    lua =
      Lua.new()
      |> Lua.load_api(Hl7toagent.Lua.ConfigApi)

    config_source = File.read!(path)
    {_result, lua} = Lua.eval!(lua, config_source)

    # Store SMTP config if present
    case Lua.get_private!(lua, :smtp) do
      nil -> :ok
      smtp -> Application.put_env(:hl7toagent, :smtp, normalize_smtp(smtp))
    end

    channels =
      lua
      |> Lua.get_private!(:channels)
      |> Enum.reverse()
      |> Enum.map(&normalize_channel_spec(&1, project_dir))

    crons =
      lua
      |> Lua.get_private!(:crons)
      |> Enum.reverse()
      |> Enum.map(&normalize_cron_spec(&1, project_dir))

    {channels, crons}
  end

  defp normalize_smtp(smtp) do
    allowed = case smtp["allowed_recipients"] do
      nil -> []
      list when is_list(list) -> Enum.map(list, fn
        {_k, v} -> v
        v -> v
      end)
      single when is_binary(single) -> [single]
    end

    [
      relay: smtp["host"] || raise("smtp: 'host' is required"),
      port: trunc(smtp["port"] || 587),
      username: smtp["username"],
      password: smtp["password"],
      from: smtp["from"] || raise("smtp: 'from' is required"),
      allowed_recipients: allowed
    ]
  end

  defp normalize_channel_spec(spec, project_dir) do
    spec = ensure_map(spec)

    %{
      name: spec["name"],
      source: normalize_source(ensure_map(spec["source"]), project_dir),
      soul: resolve_path(spec["soul"], project_dir),
      skills: ensure_list(spec["skills"]) |> Enum.map(&resolve_skill_path(&1, project_dir)),
      model: spec["model"]
    }
  end

  defp resolve_skill_path("builtin:" <> _ = builtin, _project_dir), do: builtin
  defp resolve_skill_path(path, project_dir), do: resolve_path(path, project_dir)

  defp resolve_path(nil, _project_dir), do: nil
  defp resolve_path(path, project_dir), do: Path.expand(path, project_dir)

  defp normalize_source(%{"type" => "mllp", "port" => port}, _project_dir) do
    {:mllp, %{port: trunc(port)}}
  end

  defp normalize_source(%{"type" => "http", "port" => port, "path" => path}, _project_dir) do
    {:http, %{port: trunc(port), path: path}}
  end

  defp normalize_source(%{"type" => "imap"} = src, _project_dir) do
    ssl = case src["ssl"] do
      nil -> true
      val when val == 0 -> false
      false -> false
      _ -> true
    end

    mark_read = case src["mark_read"] do
      nil -> true
      val when val == 0 -> false
      0 -> false
      false -> false
      _ -> true
    end

    {:imap,
     %{
       host: src["host"],
       port: trunc(src["port"] || 993),
       username: src["username"],
       password: src["password"],
       mailbox: src["mailbox"] || "INBOX",
       ssl: ssl,
       poll_interval: trunc(src["poll_interval"] || 30),
       mark_read: mark_read,
       search: src["search"] || "UNSEEN"
     }}
  end

  defp normalize_source(%{"type" => "file_watcher", "dir" => dir, "pattern" => pattern} = src, project_dir) do
    opts = %{dir: Path.expand(dir, project_dir), pattern: pattern}

    opts =
      if src["replies"] do
        Map.put(opts, :replies, true)
      else
        opts
      end

    {:file_watcher, opts}
  end

  defp normalize_cron_spec(spec, project_dir) do
    spec = ensure_map(spec)

    %{
      name: spec["name"],
      interval: trunc(spec["interval"] || raise("cron #{spec["name"]}: 'interval' is required")),
      script: resolve_path(spec["script"] || raise("cron #{spec["name"]}: 'script' is required"), project_dir),
      channel: spec["channel"] || raise("cron #{spec["name"]}: 'channel' is required"),
      sandbox_dir: project_dir
    }
  end

  defp ensure_map(val) when is_map(val), do: val
  defp ensure_map(val) when is_list(val), do: Lua.Table.deep_cast(val)

  defp ensure_list(val) when is_list(val) do
    case val do
      [{k, _} | _] when is_integer(k) -> Enum.sort_by(val, &elem(&1, 0)) |> Enum.map(&elem(&1, 1))
      [{_, _} | _] -> Lua.Table.deep_cast(val)
      _ -> val
    end
  end

  defp ensure_list(val), do: List.wrap(val)
end
