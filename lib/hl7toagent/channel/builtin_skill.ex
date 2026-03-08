defmodule Hl7toagent.Channel.BuiltinSkill do
  @moduledoc """
  Built-in skills that ship with hl7toagent.

  Referenced in config.lua as "builtin:name", e.g.:

      skills = { "builtin:email", "builtin:webhook", "builtin:log", "skills/custom.lua" }
  """

  require Logger

  @builtins ~w(email webhook log handoff)

  def builtin?(name), do: name in @builtins

  def load!(name) when name in @builtins do
    tool = apply(__MODULE__, :"build_#{name}", [])
    %{name: name, description: tool.description, tool: tool, path: nil, kind: :builtin}
  end

  def load!(name) do
    raise "Unknown builtin skill: #{name}. Available: #{Enum.join(@builtins, ", ")}"
  end

  # -- email --

  def build_email do
    ReqLLM.tool(
      name: "email",
      description:
        "Send an email via SMTP. Requires smtp() to be configured in config.lua.",
      parameter_schema: [
        to: [type: :string, required: true, doc: "Recipient email address"],
        subject: [type: :string, required: true, doc: "Email subject line"],
        body: [type: :string, required: true, doc: "Plain text email body"]
      ],
      callback: &do_email/1
    )
  end

  defp do_email(args) do
    to = args["to"] || args[:to] || raise "email: 'to' is required"
    subject = args["subject"] || args[:subject] || "(no subject)"
    body = args["body"] || args[:body] || ""

    smtp_config =
      Application.get_env(:hl7toagent, :smtp) ||
        raise "email: no smtp() configured in config.lua"

    case check_recipient(to, smtp_config) do
      :ok ->
        send_email(to, subject, body, smtp_config)

      {:error, reason} ->
        Logger.warning("[builtin:email] Blocked send to #{to}: #{reason}")
        {:ok, Jason.encode!(%{status: "error", error: reason})}
    end
  end

  defp check_recipient(to, smtp_config) do
    case Keyword.get(smtp_config, :allowed_recipients, []) do
      [] ->
        {:error, "no allowed_recipients configured in smtp()"}

      allowed ->
        to_lower = String.downcase(to)

        if Enum.any?(allowed, &(String.downcase(&1) == to_lower)) do
          :ok
        else
          {:error, "recipient '#{to}' is not in allowed_recipients"}
        end
    end
  end

  defp send_email(to, subject, body, smtp_config) do
    from = Keyword.fetch!(smtp_config, :from)
    message_id = generate_message_id(from)
    thread_id = Process.get(:hl7toagent_thread_id)
    channel = Process.get(:hl7toagent_channel)
    subject = tag_subject(subject, channel)

    headers =
      [
        {"From", from},
        {"To", to},
        {"Subject", subject},
        {"Message-ID", message_id},
        {"MIME-Version", "1.0"},
        {"Content-Type", "text/plain; charset=utf-8"}
      ] ++
        if(thread_id, do: [{"X-Thread-Id", thread_id}], else: [])

    header_str = Enum.map_join(headers, "\r\n", fn {k, v} -> "#{k}: #{v}" end)
    mail_body = header_str <> "\r\n\r\n" <> body

    relay = Keyword.fetch!(smtp_config, :relay)
    port = Keyword.get(smtp_config, :port, 587)
    username = Keyword.get(smtp_config, :username)
    password = Keyword.get(smtp_config, :password)

    smtp_opts =
      [relay: to_charlist(relay), port: port, tls: :if_available, tls_options: [verify: :verify_none]] ++
        if(username && password,
          do: [auth: :always, username: to_charlist(username), password: to_charlist(password)],
          else: [auth: :never]
        )

    case :gen_smtp_client.send_blocking({from, [to], mail_body}, smtp_opts) do
      receipt when is_binary(receipt) ->
        Logger.info("[builtin:email] Sent to #{to}: #{subject} (#{message_id})")

        if thread_id do
          Hl7toagent.Channel.ThreadStore.add_ref(thread_id, message_id)
        end

        {:ok, Jason.encode!(%{status: "sent", message_id: message_id})}

      {:error, reason} ->
        Logger.error("[builtin:email] Failed to send to #{to}: #{inspect(reason)}")
        {:ok, Jason.encode!(%{status: "error", error: inspect(reason)})}
    end
  end

  # -- webhook --

  def build_webhook do
    ReqLLM.tool(
      name: "webhook",
      description:
        "Send an HTTP request to an external URL. Supports GET, POST, PUT, DELETE.",
      parameter_schema: [
        url: [type: :string, required: true, doc: "The URL to send the request to"],
        method: [type: :string, required: false, doc: "HTTP method: get, post, put, delete (default: post)"],
        body: [type: :string, required: false, doc: "Request body (for POST/PUT)"],
        headers: [type: :string, required: false, doc: "JSON object of headers, e.g. {\"Content-Type\": \"application/json\"}"]
      ],
      callback: &do_webhook/1
    )
  end

  defp do_webhook(args) do
    url = args["url"] || args[:url] || raise "webhook: 'url' is required"
    method = (args["method"] || args[:method] || "post") |> String.downcase() |> String.to_atom()
    body = args["body"] || args[:body] || ""

    headers =
      case args["headers"] || args[:headers] do
        nil -> []
        h when is_binary(h) -> h |> Jason.decode!() |> Enum.map(fn {k, v} -> {k, v} end)
        h when is_map(h) -> Enum.map(h, fn {k, v} -> {to_string(k), to_string(v)} end)
      end

    req_opts = [headers: headers]

    req_opts =
      if method in [:post, :put] do
        Keyword.put(req_opts, :body, body)
      else
        req_opts
      end

    resp = apply(Req, :"#{method}!", [url, req_opts])

    Logger.info("[builtin:webhook] #{method |> to_string() |> String.upcase()} #{url} -> #{resp.status}")

    {:ok, Jason.encode!(%{status: resp.status, body: to_string(resp.body)})}
  rescue
    e ->
      Logger.error("[builtin:webhook] Error: #{Exception.message(e)}")
      {:ok, Jason.encode!(%{status: "error", error: Exception.message(e)})}
  end

  # -- log --

  def build_log do
    ReqLLM.tool(
      name: "log",
      description:
        "Write a structured log entry. Use this to record important events, decisions, or data during processing.",
      parameter_schema: [
        message: [type: :string, required: true, doc: "The log message"],
        level: [type: :string, required: false, doc: "Log level: info, warning, error (default: info)"]
      ],
      callback: &do_log/1
    )
  end

  defp do_log(args) do
    message = args["message"] || args[:message] || ""
    level = (args["level"] || args[:level] || "info") |> String.downcase()
    thread_id = Process.get(:hl7toagent_thread_id)

    prefix = if thread_id, do: "[thread:#{thread_id}] ", else: ""

    case level do
      "warning" -> Logger.warning("#{prefix}#{message}")
      "error" -> Logger.error("#{prefix}#{message}")
      _ -> Logger.info("#{prefix}#{message}")
    end

    {:ok, Jason.encode!(%{status: "logged", level: level})}
  end

  # -- handoff --

  def build_handoff do
    ReqLLM.tool(
      name: "handoff",
      description:
        "Hand off a message to another channel, optionally continuing an existing thread. " <>
        "Use this to route incoming messages to the appropriate agent, or to continue a " <>
        "conversation that was started by another channel (e.g. forwarding an email reply " <>
        "back to the agent that originally asked for more information).",
      parameter_schema: [
        channel: [type: :string, required: true, doc: "Name of the target channel to hand off to"],
        message: [type: :string, required: true, doc: "The message content to send to the target channel"],
        thread_ref: [type: :string, required: false, doc: "Thread reference (e.g. email Message-ID or In-Reply-To) to continue an existing thread"],
        thread_id: [type: :string, required: false, doc: "Explicit thread ID to continue"]
      ],
      callback: &do_handoff/1
    )
  end

  defp do_handoff(args) do
    channel = args["channel"] || args[:channel] || raise "handoff: 'channel' is required"
    message = args["message"] || args[:message] || raise "handoff: 'message' is required"
    thread_ref = args["thread_ref"] || args[:thread_ref]
    thread_id = args["thread_id"] || args[:thread_id]

    opts =
      [] ++
        if(thread_ref, do: [thread_ref: thread_ref], else: []) ++
        if(thread_id, do: [thread_id: thread_id], else: [])

    Logger.info("[builtin:handoff] Handing off to #{channel}#{if opts != [], do: " (#{inspect(opts)})", else: ""}")

    try do
      case Hl7toagent.Channel.Server.process_message(channel, message, opts) do
        {:ok, result} ->
          {:ok, Jason.encode!(%{status: "ok", channel: channel, thread_id: result.thread_id, response: result.text})}

        {:error, reason} ->
          Logger.error("[builtin:handoff] Failed to hand off to #{channel}: #{inspect(reason)}")
          {:ok, Jason.encode!(%{status: "error", error: inspect(reason)})}
      end
    catch
      :exit, {:noproc, _} ->
        Logger.error("[builtin:handoff] Channel not found: #{channel}")
        {:ok, Jason.encode!(%{status: "error", error: "channel '#{channel}' not found"})}
    end
  end

  defp tag_subject(subject, nil), do: subject
  defp tag_subject(subject, channel), do: "[#{channel}] #{subject}"

  defp generate_message_id(from) do
    domain =
      case String.split(from, "@") do
        [_, d] -> d
        _ -> "hl7toagent.local"
      end

    random = :crypto.strong_rand_bytes(12) |> Base.hex_encode32(case: :lower, padding: false)
    "<#{random}@#{domain}>"
  end
end
