defmodule Hl7toagent.Lua.EmailApi do
  @moduledoc """
  Lua API for sending emails via SMTP.

  Exposes `email.send(opts)` to Lua skills.

  SMTP config and allowed recipients are set in config.lua:

      smtp({
        host = "smtp.gmail.com",
        port = 587,
        username = env("SMTP_USERNAME"),
        password = env("SMTP_PASSWORD"),
        from = "agent@example.com"
      })

      allowed_recipients({ "alice@example.com", "bob@example.com" })
  """

  use Lua.API, scope: "email"

  require Logger

  deflua send(opts), state do
    opts = deep_decode(state, opts)

    to = opts["to"] || raise "email.send: 'to' is required"
    subject = opts["subject"] || "(no subject)"
    body = opts["body"] || ""
    thread_id = opts["thread_id"] || Process.get(:hl7toagent_thread_id)

    # Enforce recipient whitelist
    case check_recipient(to) do
      :ok ->
        do_send(to, subject, body, thread_id, state)

      {:error, reason} ->
        Logger.warning("[email] Blocked send to #{to}: #{reason}")

        {result, state} =
          Lua.encode!(state, %{"status" => "error", "error" => reason})

        {[result], state}
    end
  end

  defp check_recipient(to) do
    smtp_config = Application.get_env(:hl7toagent, :smtp, [])

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

  defp do_send(to, subject, body, thread_id, state) do
    smtp_config = Application.get_env(:hl7toagent, :smtp) ||
      raise "email.send: no smtp() configured in config.lua"

    from = Keyword.fetch!(smtp_config, :from)
    message_id = generate_message_id(from)
    channel = Process.get(:hl7toagent_channel)
    subject = tag_subject(subject, channel)

    headers = [
      {"From", from},
      {"To", to},
      {"Subject", subject},
      {"Message-ID", message_id},
      {"MIME-Version", "1.0"},
      {"Content-Type", "text/plain; charset=utf-8"}
    ]

    headers =
      if thread_id do
        headers ++ [{"X-Thread-Id", thread_id}]
      else
        headers
      end

    header_str =
      Enum.map_join(headers, "\r\n", fn {k, v} -> "#{k}: #{v}" end)

    mail_body = header_str <> "\r\n\r\n" <> body

    relay = Keyword.fetch!(smtp_config, :relay)
    port = Keyword.get(smtp_config, :port, 587)
    username = Keyword.get(smtp_config, :username)
    password = Keyword.get(smtp_config, :password)

    smtp_opts = [
      relay: to_charlist(relay),
      port: port,
      tls: :if_available,
      tls_options: [verify: :verify_none]
    ]

    smtp_opts =
      if username && password do
        smtp_opts ++
          [
            auth: :always,
            username: to_charlist(username),
            password: to_charlist(password)
          ]
      else
        smtp_opts ++ [auth: :never]
      end

    envelope = {from, [to], mail_body}

    case :gen_smtp_client.send_blocking(envelope, smtp_opts) do
      receipt when is_binary(receipt) ->
        Logger.info("[email] Sent to #{to}: #{subject} (#{message_id})")

        if thread_id do
          Hl7toagent.Channel.ThreadStore.add_ref(thread_id, message_id)
        end

        {result, state} =
          Lua.encode!(state, %{"status" => "sent", "message_id" => message_id})

        {[result], state}

      {:error, reason} ->
        Logger.error("[email] Failed to send to #{to}: #{inspect(reason)}")

        {result, state} =
          Lua.encode!(state, %{"status" => "error", "error" => inspect(reason)})

        {[result], state}
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

  defp deep_decode(state, {:tref, _} = tref) do
    state
    |> Lua.decode!(tref)
    |> deep_decode_kv(state)
  end

  defp deep_decode(_state, other), do: other

  defp deep_decode_kv(kv_list, state) when is_list(kv_list) do
    if Enum.all?(kv_list, fn {k, _} -> is_integer(k) end) do
      kv_list
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {_k, v} -> deep_decode(state, v) end)
    else
      Map.new(kv_list, fn {k, v} -> {k, deep_decode(state, v)} end)
    end
  end
end
