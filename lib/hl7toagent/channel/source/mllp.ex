defmodule Hl7toagent.Channel.Source.Mllp do
  @moduledoc """
  MLLP source — creates a dynamic dispatcher and returns an MLLP.Receiver child spec.
  """

  def child_spec({channel_name, opts}) do
    dispatcher_module = Module.concat(Hl7toagent.Dispatcher, Macro.camelize(channel_name))

    unless Code.ensure_loaded?(dispatcher_module) do
      channel_name_val = channel_name

      {:module, ^dispatcher_module, _, _} =
        Module.create(
          dispatcher_module,
          quote do
            @behaviour MLLP.Dispatcher
            @channel_name unquote(channel_name_val)

            require Logger

            @impl true
            def dispatch(:mllp_hl7, raw_hl7, state) when is_binary(raw_hl7) do
              Logger.info("[#{@channel_name}] MLLP received message")

              project_dir = Application.get_env(:hl7toagent, :project_dir, File.cwd!())

              ack_code =
                with {:ok, processing_path} <-
                       Hl7toagent.Channel.Pipeline.stage_data(raw_hl7, "message.hl7", project_dir),
                     {:ok, _result} <-
                       Hl7toagent.Channel.Server.process_message(
                         @channel_name,
                         {:file, processing_path, raw_hl7}
                       ) do
                  :application_accept
                else
                  {:error, _reason} -> :application_reject
                end

              reply =
                raw_hl7
                |> HL7.Message.new()
                |> MLLP.Ack.get_ack_for_message(ack_code)
                |> to_string()
                |> MLLP.Envelope.wrap_message()

              {:ok, %{state | reply_buffer: reply}}
            end

            def dispatch(:mllp_unknown, _message, state) do
              Logger.warning("[#{@channel_name}] MLLP received non-HL7 message")
              {:ok, %{state | reply_buffer: MLLP.Envelope.wrap_message("")}}
            end
          end,
          Macro.Env.location(__ENV__)
        )
    end

    MLLP.Receiver.child_spec(port: opts.port, dispatcher: dispatcher_module)
  end
end
