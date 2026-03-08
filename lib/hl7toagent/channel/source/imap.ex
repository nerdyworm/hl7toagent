defmodule Hl7toagent.Channel.Source.Imap do
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
    poll_interval = Map.get(opts, :poll_interval, 30) * 1_000
    mark_read = Map.get(opts, :mark_read, true)

    search = Map.get(opts, :search, "UNSEEN")

    state = %{
      channel_name: channel_name,
      host: opts.host,
      port: opts.port,
      username: opts.username,
      password: opts.password,
      mailbox: Map.get(opts, :mailbox, "INBOX"),
      ssl: Map.get(opts, :ssl, true),
      poll_interval: poll_interval,
      mark_read: mark_read,
      search: search
    }

    Logger.info(
      "[#{channel_name}] IMAP source polling #{opts.host}:#{opts.port} every #{div(poll_interval, 1_000)}s"
    )

    schedule_poll(0)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    Task.start(fn -> poll_mailbox(state) end)
    schedule_poll(state.poll_interval)
    {:noreply, state}
  end

  defp schedule_poll(delay) do
    Process.send_after(self(), :poll, delay)
  end

  defp poll_mailbox(state) do
    case connect(state) do
      {:ok, client} ->
        try do
          client = Mailroom.IMAP.select(client, state.mailbox)

          case Mailroom.IMAP.search(client, state.search) do
            {:ok, []} ->
              :ok

            {:ok, msg_ids} ->
              Logger.info("[#{state.channel_name}] Found #{length(msg_ids)} new email(s)")

              msg_ids
              |> Mailroom.IMAP.Utils.numbers_to_sequences()
              |> Enum.each(fn seq ->
                case Mailroom.IMAP.fetch(client, seq, [:envelope, :rfc822]) do
                  {:ok, messages} ->
                    Enum.each(messages, fn {msg_num, msg} ->
                      process_email(state, client, msg_num, msg)
                    end)

                  {:error, reason} ->
                    Logger.error("[#{state.channel_name}] IMAP fetch failed: #{inspect(reason)}")
                end
              end)

            {:error, reason} ->
              Logger.error("[#{state.channel_name}] IMAP search failed: #{inspect(reason)}")
          end
        after
          Mailroom.IMAP.logout(client)
        end

      {:error, reason} ->
        Logger.error("[#{state.channel_name}] IMAP connect failed: #{inspect(reason)}")
    end
  end

  defp connect(state) do
    Mailroom.IMAP.connect(
      state.host,
      state.username,
      state.password,
      port: state.port,
      ssl: state.ssl,
      ssl_opts: [verify: :verify_none],
      timeout: 30_000
    )
  end

  defp process_email(state, client, msg_num, msg) do
    project_dir = Application.get_env(:hl7toagent, :project_dir, File.cwd!())
    email = Mail.Parsers.RFC2822.parse(msg.rfc822)

    envelope = msg.envelope
    subject = envelope.subject || "(no subject)"
    from = format_address(envelope.from)

    # Extract thread routing from headers
    thread_opts = extract_thread_opts(envelope)

    # Build a readable message for the LLM
    body = extract_body(email)

    message =
      "From: #{from}\nSubject: #{subject}\n\n#{body}"

    # Stage the raw email
    filename = "email_#{System.system_time(:millisecond)}.eml"

    case Pipeline.stage_data(msg.rfc822, filename, project_dir) do
      {:ok, processing_path} ->
        # Find the right channel (may differ if this is a reply to another channel's thread)
        {target_channel, thread_opts} = resolve_reply_target(state.channel_name, thread_opts)

        case Hl7toagent.Channel.Server.process_message(
               target_channel,
               {:file, processing_path, message},
               thread_opts
             ) do
          {:ok, _result} ->
            Logger.info("[#{state.channel_name}] Processed email: #{subject}")

            if state.mark_read do
              Mailroom.IMAP.add_flags(client, msg_num, [:seen], silent: true)
            end

          {:error, reason} ->
            Logger.error(
              "[#{state.channel_name}] Failed to process email '#{subject}': #{inspect(reason)}"
            )
        end

      {:error, reason} ->
        Logger.error("[#{state.channel_name}] Failed to stage email: #{inspect(reason)}")
    end
  end

  defp extract_thread_opts(envelope) do
    opts = []

    # Check for X-Thread-Id in message_id (our custom header gets picked up here)
    # and In-Reply-To for standard email threading
    opts =
      if envelope.in_reply_to && envelope.in_reply_to != "" do
        [{:thread_ref, envelope.in_reply_to} | opts]
      else
        opts
      end

    opts
  end

  defp resolve_reply_target(fallback_channel, thread_opts) do
    cond do
      thread_ref = Keyword.get(thread_opts, :thread_ref) ->
        case ThreadStore.find_by_ref(thread_ref) do
          {:ok, thread_id} ->
            case ThreadStore.get_thread(thread_id) do
              {:ok, %{channel_name: original_channel}} ->
                opts = Keyword.put(thread_opts, :thread_id, thread_id)
                {original_channel, opts}

              {:error, :not_found} ->
                {fallback_channel, thread_opts}
            end

          {:error, :not_found} ->
            {fallback_channel, thread_opts}
        end

      true ->
        {fallback_channel, thread_opts}
    end
  end

  defp extract_body(%Mail.Message{body: body, parts: []}) when is_binary(body), do: body

  defp extract_body(%Mail.Message{parts: parts}) when is_list(parts) and parts != [] do
    # Prefer text/plain, fall back to text/html stripped
    text_part = Enum.find(parts, fn part -> content_type(part) == "text/plain" end)
    html_part = Enum.find(parts, fn part -> content_type(part) == "text/html" end)

    cond do
      text_part && text_part.body -> text_part.body
      html_part && html_part.body -> strip_html(html_part.body)
      true -> ""
    end
  end

  defp extract_body(_), do: ""

  defp content_type(%Mail.Message{headers: headers}) do
    case headers["content-type"] do
      [type | _] when is_binary(type) -> type
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  defp strip_html(html) do
    html
    |> String.replace(~r/<br\s*\/?>/, "\n")
    |> String.replace(~r/<\/p>/, "\n\n")
    |> String.replace(~r/<[^>]+>/, "")
    |> String.trim()
  end

  defp format_address([%{name: name, email: email} | _]) when name != nil and name != "" do
    "#{name} <#{email}>"
  end

  defp format_address([%{email: email} | _]), do: email
  defp format_address(_), do: "unknown"
end
