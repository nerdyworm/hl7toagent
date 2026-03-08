defmodule Hl7toagent.Cron.Runner do
  @moduledoc """
  GenServer that runs a Lua script on an interval and sends
  results to a target channel. Acts as a scheduled producer.
  """

  use GenServer

  require Logger

  def start_link(cron_spec) do
    GenServer.start_link(__MODULE__, cron_spec)
  end

  def child_spec(cron_spec) do
    %{
      id: :"cron_#{cron_spec.name}",
      start: {__MODULE__, :start_link, [cron_spec]}
    }
  end

  @impl true
  def init(spec) do
    interval_ms = spec.interval * 1_000

    Logger.info("[cron:#{spec.name}] Starting — every #{spec.interval}s → #{spec.channel}")

    schedule(interval_ms)

    {:ok,
     %{
       name: spec.name,
       interval: interval_ms,
       script: spec.script,
       channel: spec.channel,
       sandbox_dir: spec.sandbox_dir
     }}
  end

  @impl true
  def handle_info(:tick, state) do
    Task.start(fn -> run_and_forward(state) end)
    schedule(state.interval)
    {:noreply, state}
  end

  defp schedule(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp run_and_forward(state) do
    case run_script(state) do
      {:ok, nil} ->
        :ok

      {:ok, results} when is_list(results) ->
        Enum.each(results, fn message ->
          forward(state, message)
        end)

      {:ok, message} ->
        forward(state, message)

      {:error, reason} ->
        Logger.error("[cron:#{state.name}] Script error: #{inspect(reason)}")
    end
  end

  defp forward(state, message) when is_binary(message) and message != "" do
    Logger.info("[cron:#{state.name}] Forwarding message to #{state.channel}")

    case Hl7toagent.Channel.Server.process_message(state.channel, message) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.error("[cron:#{state.name}] Channel #{state.channel} error: #{inspect(reason)}")
    end
  end

  defp forward(_state, _empty), do: :ok

  defp run_script(state) do
    lua =
      Lua.new()
      |> Lua.put_private(:sandbox_dir, state.sandbox_dir)
      |> Lua.load_api(Hl7toagent.Lua.HttpApi)
      |> Lua.load_api(Hl7toagent.Lua.FileApi)

    {[script_table], lua} = Lua.eval!(lua, File.read!(state.script), decode: false)
    {[run_ref], lua} = Lua.call_function!(lua, [:rawget], [script_table, "run"])

    case Lua.call_function(lua, run_ref, []) do
      {:ok, [nil], _lua} ->
        {:ok, nil}

      {:ok, [{:tref, _} = tref], lua} ->
        decoded = deep_decode(lua, tref)
        {:ok, normalize_results(decoded)}

      {:ok, [val], _lua} when is_binary(val) ->
        {:ok, val}

      {:ok, [], _lua} ->
        {:ok, nil}

      {:error, reason, _lua} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp normalize_results(list) when is_list(list), do: Enum.map(list, &to_message/1)
  defp normalize_results(map) when is_map(map), do: to_message(map)
  defp normalize_results(val) when is_binary(val), do: val
  defp normalize_results(_), do: nil

  defp to_message(val) when is_binary(val), do: val
  defp to_message(val) when is_map(val), do: Jason.encode!(val)
  defp to_message(val) when is_list(val), do: Jason.encode!(Map.new(val))
  defp to_message(_), do: nil

  defp deep_decode(lua, {:tref, _} = tref) do
    lua
    |> Lua.decode!(tref)
    |> deep_decode_kv(lua)
  end

  defp deep_decode(_lua, val), do: val

  defp deep_decode_kv(kv_list, lua) when is_list(kv_list) do
    if Enum.all?(kv_list, fn {k, _} -> is_integer(k) end) do
      kv_list
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {_k, v} -> deep_decode(lua, v) end)
    else
      Map.new(kv_list, fn {k, v} -> {k, deep_decode(lua, v)} end)
    end
  end
end
