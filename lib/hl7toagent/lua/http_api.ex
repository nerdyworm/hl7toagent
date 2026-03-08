defmodule Hl7toagent.Lua.HttpApi do
  use Lua.API, scope: "http"

  deflua get(url), state do
    resp = Req.get!(url)

    {result, state} =
      Lua.encode!(state, %{"status" => resp.status, "body" => to_string(resp.body)})

    {[result], state}
  end

  deflua post(url, opts), state do
    opts = state |> Lua.decode!(opts) |> Lua.Table.deep_cast()
    body = Map.get(opts, "body", "")
    headers = Map.get(opts, "headers", %{})

    resp = Req.post!(url, body: body, headers: cast_headers(headers))

    {result, state} =
      Lua.encode!(state, %{"status" => resp.status, "body" => to_string(resp.body)})

    {[result], state}
  end

  deflua put(url, opts), state do
    opts = state |> Lua.decode!(opts) |> Lua.Table.deep_cast()
    body = Map.get(opts, "body", "")
    headers = Map.get(opts, "headers", %{})

    resp = Req.put!(url, body: body, headers: cast_headers(headers))

    {result, state} =
      Lua.encode!(state, %{"status" => resp.status, "body" => to_string(resp.body)})

    {[result], state}
  end

  deflua delete(url), state do
    resp = Req.delete!(url)

    {result, state} =
      Lua.encode!(state, %{"status" => resp.status, "body" => to_string(resp.body)})

    {[result], state}
  end

  defp cast_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp cast_headers(_), do: []
end
