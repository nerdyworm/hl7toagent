defmodule Hl7toagent.Channel.Source.Http do
  @moduledoc """
  HTTP source — uses a Plug module that dispatches to the channel server.
  """

  def child_spec({channel_name, opts}) do
    plug = {Hl7toagent.Channel.Source.Http.Plug, channel_name: channel_name, path: opts.path}
    {Bandit, plug: plug, port: opts.port}
  end
end

defmodule Hl7toagent.Channel.Source.Http.Plug do
  @behaviour Plug

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    channel_name = Keyword.fetch!(opts, :channel_name)
    path = Keyword.fetch!(opts, :path)

    case {conn.method, conn.request_path} do
      {"GET", "/health"} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{status: "ok", channel: channel_name}))

      {"POST", ^path} ->
        {:ok, body, conn} = read_body(conn)
        project_dir = Application.get_env(:hl7toagent, :project_dir, File.cwd!())

        # Extract thread routing from JSON body or headers
        thread_opts = extract_thread_opts(conn, body)

        with {:ok, processing_path} <-
               Hl7toagent.Channel.Pipeline.stage_data(body, "request.dat", project_dir),
             {:ok, result} <-
               Hl7toagent.Channel.Server.process_message(
                 channel_name,
                 {:file, processing_path, body},
                 thread_opts
               ) do
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{status: "ok", result: result}))
        else
          {:error, reason} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(422, Jason.encode!(%{status: "error", reason: inspect(reason)}))
        end

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{error: "not found"}))
    end
  end

  defp extract_thread_opts(conn, body) do
    # Check headers first
    thread_id = get_req_header(conn, "x-thread-id") |> List.first()
    thread_ref = get_req_header(conn, "x-thread-ref") |> List.first()

    # Fall back to JSON body fields
    {thread_id, thread_ref} =
      case Jason.decode(body) do
        {:ok, %{"thread_id" => tid}} when not is_nil(tid) and is_nil(thread_id) ->
          {tid, thread_ref}

        {:ok, %{"thread_ref" => tref}} when not is_nil(tref) and is_nil(thread_ref) ->
          {thread_id, tref}

        {:ok, %{"thread_id" => tid, "thread_ref" => tref}} ->
          {thread_id || tid, thread_ref || tref}

        _ ->
          {thread_id, thread_ref}
      end

    opts = []
    opts = if thread_id, do: [{:thread_id, thread_id} | opts], else: opts
    opts = if thread_ref, do: [{:thread_ref, thread_ref} | opts], else: opts
    opts
  end
end
