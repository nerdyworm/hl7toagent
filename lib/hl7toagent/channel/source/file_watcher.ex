defmodule Hl7toagent.Channel.Source.FileWatcher do
  use GenServer

  require Logger

  alias Hl7toagent.Channel.{Pipeline, ThreadStore}

  def start_link({channel_name, opts}) do
    GenServer.start_link(__MODULE__, {channel_name, opts})
  end

  def child_spec({channel_name, opts}) do
    %{
      id: {__MODULE__, channel_name},
      start: {__MODULE__, :start_link, [{channel_name, opts}]}
    }
  end

  @impl true
  def init({channel_name, opts}) do
    dir = opts.dir
    pattern = opts.pattern
    replies = Map.get(opts, :replies, false)

    File.mkdir_p!(dir)
    {:ok, pid} = FileSystem.start_link(dirs: [dir])
    FileSystem.subscribe(pid)

    mode = if replies, do: "replies", else: "files"
    Logger.info("[#{channel_name}] FileWatcher monitoring #{dir} for #{pattern} (#{mode})")

    {:ok,
     %{
       channel_name: channel_name,
       watcher_pid: pid,
       dir: dir,
       pattern: pattern,
       replies: replies,
       pending: %{}
     }}
  end

  @debounce_ms 500

  @impl true
  def handle_info({:file_event, _pid, {path, events}}, state) do
    if (:created in events or :modified in events) and matches_pattern?(path, state.pattern) and
         not Map.has_key?(state.pending, path) do
      ref = Process.send_after(self(), {:process_file, path}, @debounce_ms)
      {:noreply, %{state | pending: Map.put(state.pending, path, ref)}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:process_file, path}, state) do
    if state.replies do
      Task.start(fn -> process_reply(state.channel_name, path) end)
    else
      Task.start(fn -> process_file(state.channel_name, path) end)
    end

    {:noreply, %{state | pending: Map.delete(state.pending, path)}}
  end

  def handle_info({:file_event, _pid, :stop}, state) do
    Logger.warning("[#{state.channel_name}] FileWatcher stopped")
    {:noreply, state}
  end

  defp process_file(channel_name, path) do
    project_dir = Application.get_env(:hl7toagent, :project_dir, File.cwd!())

    case Pipeline.stage(path, project_dir) do
      {:ok, processing_path, contents} ->
        relative = Path.relative_to(processing_path, project_dir)
        Logger.info("[#{channel_name}] Staged #{Path.basename(path)} → #{relative}")

        thread_opts = extract_thread_opts(contents)

        case Hl7toagent.Channel.Server.process_message(
               channel_name,
               {:file, processing_path, contents},
               thread_opts
             ) do
          {:ok, _result} ->
            Logger.info("[#{channel_name}] Processed #{Path.basename(path)}")

          {:error, reason} ->
            Logger.error(
              "[#{channel_name}] Failed to process #{Path.basename(path)}: #{inspect(reason)}"
            )
        end

      {:error, reason} ->
        Logger.error("[#{channel_name}] Failed to stage #{path}: #{reason}")
    end
  end

  defp process_reply(channel_name, path) do
    project_dir = Application.get_env(:hl7toagent, :project_dir, File.cwd!())

    case Pipeline.stage(path, project_dir) do
      {:ok, processing_path, contents} ->
        relative = Path.relative_to(processing_path, project_dir)
        Logger.info("[#{channel_name}] Staged reply #{Path.basename(path)} → #{relative}")

        thread_opts = extract_thread_opts(contents)
        body = extract_email_body(contents)

        # Find which channel owns this thread
        {target_channel, thread_opts} = resolve_reply_target(channel_name, thread_opts)

        case Hl7toagent.Channel.Server.process_message(
               target_channel,
               {:file, processing_path, body},
               thread_opts
             ) do
          {:ok, _result} ->
            Logger.info("[#{channel_name}] Reply routed to #{target_channel}")

          {:error, reason} ->
            Logger.error(
              "[#{channel_name}] Failed to route reply: #{inspect(reason)}"
            )
        end

      {:error, reason} ->
        Logger.error("[#{channel_name}] Failed to stage reply #{path}: #{reason}")
    end
  end

  defp resolve_reply_target(fallback_channel, thread_opts) do
    # Try to find the original channel via thread_id or thread_ref
    cond do
      thread_id = Keyword.get(thread_opts, :thread_id) ->
        case ThreadStore.get_thread(thread_id) do
          {:ok, %{channel_name: original_channel}} ->
            {original_channel, thread_opts}

          {:error, :not_found} ->
            Logger.warning("[#{fallback_channel}] Thread #{thread_id} not found, using fallback")
            {fallback_channel, thread_opts}
        end

      thread_ref = Keyword.get(thread_opts, :thread_ref) ->
        case ThreadStore.find_by_ref(thread_ref) do
          {:ok, thread_id} ->
            case ThreadStore.get_thread(thread_id) do
              {:ok, %{channel_name: original_channel}} ->
                # Replace thread_ref with resolved thread_id for efficiency
                opts = Keyword.put(thread_opts, :thread_id, thread_id)
                {original_channel, opts}

              {:error, :not_found} ->
                {fallback_channel, thread_opts}
            end

          {:error, :not_found} ->
            Logger.warning("[#{fallback_channel}] No thread found for ref #{thread_ref}")
            {fallback_channel, thread_opts}
        end

      true ->
        Logger.warning("[#{fallback_channel}] Reply has no thread references, using fallback")
        {fallback_channel, thread_opts}
    end
  end

  defp extract_thread_opts(contents) do
    opts = []

    opts =
      case Regex.run(~r/^X-Thread-Id:\s*(.+)$/mi, contents) do
        [_, thread_id] -> [{:thread_id, String.trim(thread_id)} | opts]
        _ -> opts
      end

    opts =
      case Regex.run(~r/^In-Reply-To:\s*(.+)$/mi, contents) do
        [_, ref] -> [{:thread_ref, String.trim(ref)} | opts]
        _ -> opts
      end

    opts
  end

  defp extract_email_body(contents) do
    # Split on the first blank line (header/body separator in RFC 2822)
    case String.split(contents, ~r/\r?\n\r?\n/, parts: 2) do
      [_headers, body] -> String.trim(body)
      [single] -> single
    end
  end

  defp matches_pattern?(path, pattern) do
    filename = Path.basename(path)

    regex =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> then(&"^#{&1}$")
      |> Regex.compile!()

    Regex.match?(regex, filename)
  end
end
