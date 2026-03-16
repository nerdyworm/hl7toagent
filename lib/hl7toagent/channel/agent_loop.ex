defmodule Hl7toagent.Channel.AgentLoop do
  @moduledoc """
  Reusable LLM tool loop. Used by Channel.Server for top-level agents
  and by Channel.Skill for sub-agent skills.
  """

  require Logger

  @max_tool_rounds 20
  @default_model "openai:gpt-5-mini"

  def run(messages, tools, opts \\ []) do
    model = Keyword.get(opts, :model, @default_model)
    max_rounds = Keyword.get(opts, :max_rounds, @max_tool_rounds)
    label = Keyword.get(opts, :label, "agent")

    # Make thread_id and channel label available to skill callbacks via process dictionary
    if thread_id = Keyword.get(opts, :thread_id) do
      Process.put(:hl7toagent_thread_id, thread_id)
    end

    Process.put(:hl7toagent_channel, label)

    context =
      case messages do
        %ReqLLM.Context{} -> messages
        msgs when is_list(msgs) -> ReqLLM.Context.new(msgs)
      end

    tool_loop(context, tools, 1, model, max_rounds, label)
  end

  defp tool_loop(context, _tools, round, _model, max_rounds, _label) when round > max_rounds do
    {:ok, "Max tool rounds reached", context}
  end

  defp tool_loop(context, tools, round, model, max_rounds, label) do
    Logger.info("[#{label}] LLM call round #{round} → #{model} (#{length(tools)} tools)")

    case ReqLLM.generate_text(model, context, tools: tools, on_unsupported: :ignore) do
      {:ok, response} ->
        log_thinking(label, round, response)
        log_usage(label, round, response)
        tool_calls = ReqLLM.Response.tool_calls(response)

        if tool_calls == [] do
          text = ReqLLM.Response.text(response)

          Logger.info("[#{label}] Final response (round #{round}):\n#{text}")

          {:ok, text, response.context}
        else
          Enum.each(tool_calls, fn call ->
            call_name = ReqLLM.ToolCall.name(call)
            call_args = ReqLLM.ToolCall.args_map(call) || %{}

            Logger.info(
              "[#{label}] Tool call round #{round}: #{call_name}(#{Jason.encode!(call_args)})"
            )
          end)

          updated_context =
            Enum.reduce(tool_calls, response.context, fn call, ctx ->
              call_name = ReqLLM.ToolCall.name(call)
              call_args = ReqLLM.ToolCall.args_map(call) || %{}
              tool = Enum.find(tools, &(&1.name == call_name))

              result =
                if tool do
                  case ReqLLM.Tool.execute(tool, call_args) do
                    {:ok, res} -> res
                    {:error, err} -> Jason.encode!(%{error: inspect(err)})
                  end
                else
                  Jason.encode!(%{error: "Unknown tool: #{call_name}"})
                end

              ReqLLM.Context.append(ctx, ReqLLM.Context.tool_result(call.id, call_name, result))
            end)

          tool_loop(updated_context, tools, round + 1, model, max_rounds, label)
        end

      {:error, reason} ->
        Logger.error("[#{label}] LLM error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp log_thinking(label, round, response) do
    case ReqLLM.Response.thinking(response) do
      nil ->
        :ok

      "" ->
        :ok

      thinking ->
        reasoning_count = ReqLLM.Response.reasoning_tokens(response)
        token_str = if reasoning_count > 0, do: " (#{reasoning_count} tokens)", else: ""
        Logger.info("[#{label}] Thinking round #{round}#{token_str}:\n#{thinking}")
    end
  end

  defp log_usage(label, round, response) do
    case ReqLLM.Response.usage(response) do
      %{} = usage ->
        input = Map.get(usage, :input_tokens, "?")
        output = Map.get(usage, :output_tokens, "?")
        reasoning = ReqLLM.Response.reasoning_tokens(response)
        cost = Map.get(usage, :total_cost)
        reasoning_str = if reasoning > 0, do: " reasoning=#{reasoning}", else: ""
        cost_str = if cost, do: " | $#{:erlang.float_to_binary(cost / 1, decimals: 6)}", else: ""

        Logger.info(
          "[#{label}] Usage round #{round}: in=#{input} out=#{output}#{reasoning_str}#{cost_str}"
        )

      _ ->
        :ok
    end
  end
end
