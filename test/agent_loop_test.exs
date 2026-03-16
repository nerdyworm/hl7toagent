defmodule Hl7toagent.Channel.AgentLoopTest do
  use ExUnit.Case, async: true

  alias Hl7toagent.Channel.AgentLoop
  alias ReqLLM.{Context, Message, ToolCall}
  alias ReqLLM.Message.ContentPart

  # -- helpers ---------------------------------------------------------------

  defp text_response(text) do
    message = %Message{
      role: :assistant,
      content: [ContentPart.text(text)]
    }

    {:ok,
     %ReqLLM.Response{
       id: "resp_#{System.unique_integer([:positive])}",
       model: "test",
       context: Context.new(),
       message: message,
       finish_reason: :stop
     }}
  end

  # Like text_response but carries the input context forward (for assertions on final context)
  defp text_response_with_context(text, context) do
    message = %Message{
      role: :assistant,
      content: [ContentPart.text(text)]
    }

    updated_context = Context.append(context, message)

    {:ok,
     %ReqLLM.Response{
       id: "resp_#{System.unique_integer([:positive])}",
       model: "test",
       context: updated_context,
       message: message,
       finish_reason: :stop
     }}
  end

  # Returns a function that builds a tool_call response carrying the input context forward,
  # like a real LLM provider would.
  defp tool_call_response(calls) do
    fn _model, context, _opts ->
      tool_calls =
        Enum.map(calls, fn {name, args} ->
          ToolCall.new("call_#{name}", name, Jason.encode!(args))
        end)

      message = %Message{
        role: :assistant,
        content: [],
        tool_calls: tool_calls
      }

      # Real LLM returns context = input context + assistant message
      updated_context = Context.append(context, message)

      {:ok,
       %ReqLLM.Response{
         id: "resp_#{System.unique_integer([:positive])}",
         model: "test",
         context: updated_context,
         message: message,
         finish_reason: :tool_calls
       }}
    end
  end

  defp make_tool(name, description, callback) do
    ReqLLM.tool(
      name: name,
      description: description,
      parameter_schema: [message: [type: :string, required: true, doc: "input"]],
      callback: callback
    )
  end

  defp make_tool(name, description, schema, callback) do
    ReqLLM.tool(
      name: name,
      description: description,
      parameter_schema: schema,
      callback: callback
    )
  end

  # Builds a generate_fn that returns canned responses in order.
  # Each element is either a response tuple or a function receiving (model, context, opts).
  defp sequenced_generate(responses) do
    ref = :counters.new(1, [:atomics])

    fn model, context, opts ->
      idx = :counters.get(ref, 1)
      :counters.add(ref, 1, 1)

      case Enum.at(responses, idx) do
        nil ->
          raise "sequenced_generate: ran out of responses at index #{idx}"

        fun when is_function(fun, 3) ->
          fun.(model, context, opts)

        response ->
          response
      end
    end
  end

  # -- tests -----------------------------------------------------------------

  describe "simple text response (no tools)" do
    test "returns LLM text when no tool calls" do
      generate_fn = fn _model, _context, _opts ->
        text_response("Hello, world!")
      end

      messages = [
        %{"role" => "system", "content" => "You are helpful."},
        %{"role" => "user", "content" => "Hi"}
      ]

      {:ok, text, _ctx} = AgentLoop.run(messages, [], generate_fn: generate_fn)
      assert text == "Hello, world!"
    end

    test "accepts a ReqLLM.Context as input" do
      generate_fn = fn _model, _context, _opts ->
        text_response("From context")
      end

      context = Context.new([Context.user("Hello")])
      {:ok, text, _ctx} = AgentLoop.run(context, [], generate_fn: generate_fn)
      assert text == "From context"
    end
  end

  describe "tool calling loop" do
    test "executes a tool and loops back to LLM with result" do
      tool =
        make_tool("greet", "Greet a person", fn args ->
          {:ok, Jason.encode!(%{greeting: "Hello, #{args["message"]}!"})}
        end)

      generate_fn =
        sequenced_generate([
          # Round 1: LLM calls the greet tool
          tool_call_response([{"greet", %{message: "Alice"}}]),
          # Round 2: LLM produces final text
          fn _model, _context, _opts ->
            text_response("I greeted Alice for you.")
          end
        ])

      messages = [%{"role" => "user", "content" => "Say hi to Alice"}]
      {:ok, text, _ctx} = AgentLoop.run(messages, [tool], generate_fn: generate_fn)
      assert text == "I greeted Alice for you."
    end

    test "tool callback result is passed back to LLM in context" do
      tool =
        make_tool("lookup", "Look up data", fn _args ->
          {:ok, Jason.encode!(%{found: "patient_123"})}
        end)

      captured_context = :ets.new(:captured, [:set, :public])

      generate_fn =
        sequenced_generate([
          tool_call_response([{"lookup", %{message: "find patient"}}]),
          fn _model, context, _opts ->
            :ets.insert(captured_context, {:ctx, context})
            text_response("Found it.")
          end
        ])

      {:ok, _text, _ctx} = AgentLoop.run([%{"role" => "user", "content" => "find"}], [tool],
        generate_fn: generate_fn
      )

      [{:ctx, ctx}] = :ets.lookup(captured_context, :ctx)
      # The context should contain a tool result message
      tool_msgs = Enum.filter(ctx.messages, &match?(%Message{role: :tool}, &1))
      assert length(tool_msgs) == 1
      [tool_msg] = tool_msgs
      tool_text = tool_msg.content |> Enum.map(& &1.text) |> Enum.join()
      assert tool_text =~ "patient_123"
    end

    test "multiple tool calls in a single round" do
      call_log = :ets.new(:calls, [:bag, :public])

      tool_a =
        make_tool("tool_a", "Tool A", fn args ->
          :ets.insert(call_log, {:call, "tool_a", args[:message]})
          {:ok, Jason.encode!(%{a: "done"})}
        end)

      tool_b =
        make_tool("tool_b", "Tool B", fn args ->
          :ets.insert(call_log, {:call, "tool_b", args[:message]})
          {:ok, Jason.encode!(%{b: "done"})}
        end)

      generate_fn =
        sequenced_generate([
          # Round 1: LLM calls both tools
          tool_call_response([{"tool_a", %{message: "x"}}, {"tool_b", %{message: "y"}}]),
          # Round 2: final response
          fn _m, _c, _o -> text_response("Both done.") end
        ])

      {:ok, text, _ctx} =
        AgentLoop.run([%{"role" => "user", "content" => "do both"}], [tool_a, tool_b],
          generate_fn: generate_fn
        )

      assert text == "Both done."
      calls = :ets.tab2list(call_log)
      assert {:call, "tool_a", "x"} in calls
      assert {:call, "tool_b", "y"} in calls
    end

    test "multi-round tool loop (tool → tool → final)" do
      round_counter = :counters.new(1, [:atomics])

      tool =
        make_tool("step", "Do a step", fn _args ->
          :counters.add(round_counter, 1, 1)
          count = :counters.get(round_counter, 1)
          {:ok, Jason.encode!(%{step: count})}
        end)

      generate_fn =
        sequenced_generate([
          tool_call_response([{"step", %{message: "1"}}]),
          tool_call_response([{"step", %{message: "2"}}]),
          fn _m, _c, _o -> text_response("Done after 2 steps.") end
        ])

      {:ok, text, _ctx} =
        AgentLoop.run([%{"role" => "user", "content" => "go"}], [tool],
          generate_fn: generate_fn
        )

      assert text == "Done after 2 steps."
      assert :counters.get(round_counter, 1) == 2
    end
  end

  describe "unknown tool handling" do
    test "returns error JSON for unknown tool name" do
      captured_context = :ets.new(:captured_unknown, [:set, :public])

      generate_fn =
        sequenced_generate([
          # LLM calls a tool that doesn't exist
          tool_call_response([{"nonexistent", %{message: "x"}}]),
          fn _model, context, _opts ->
            :ets.insert(captured_context, {:ctx, context})
            text_response("I see the error.")
          end
        ])

      {:ok, text, _ctx} =
        AgentLoop.run([%{"role" => "user", "content" => "test"}], [],
          generate_fn: generate_fn
        )

      assert text == "I see the error."

      [{:ctx, ctx}] = :ets.lookup(captured_context, :ctx)
      tool_msgs = Enum.filter(ctx.messages, &match?(%Message{role: :tool}, &1))
      assert length(tool_msgs) == 1
      [tool_msg] = tool_msgs
      tool_text = tool_msg.content |> Enum.map(& &1.text) |> Enum.join()
      assert tool_text =~ "Unknown tool"
      assert tool_text =~ "nonexistent"
    end
  end

  describe "tool execution errors" do
    test "tool callback returning {:error, reason} produces error JSON in context" do
      captured_context = :ets.new(:captured_err, [:set, :public])

      tool =
        make_tool("fail_tool", "Always fails", fn _args ->
          {:error, "connection refused"}
        end)

      generate_fn =
        sequenced_generate([
          tool_call_response([{"fail_tool", %{message: "try"}}]),
          fn _model, context, _opts ->
            :ets.insert(captured_context, {:ctx, context})
            text_response("Tool failed.")
          end
        ])

      {:ok, text, _ctx} =
        AgentLoop.run([%{"role" => "user", "content" => "go"}], [tool],
          generate_fn: generate_fn
        )

      assert text == "Tool failed."

      [{:ctx, ctx}] = :ets.lookup(captured_context, :ctx)
      tool_msgs = Enum.filter(ctx.messages, &match?(%Message{role: :tool}, &1))
      assert length(tool_msgs) == 1
      [tool_msg] = tool_msgs
      tool_text = tool_msg.content |> Enum.map(& &1.text) |> Enum.join()
      assert tool_text =~ "connection refused"
    end
  end

  describe "max rounds" do
    test "stops after max_rounds and returns sentinel text" do
      # Always return a tool call — loop should stop at max_rounds
      generate_fn = fn model, context, opts ->
        tool_call_response([{"ping", %{message: "again"}}]).(model, context, opts)
      end

      tool =
        make_tool("ping", "Ping", fn _args ->
          {:ok, Jason.encode!(%{pong: true})}
        end)

      {:ok, text, _ctx} =
        AgentLoop.run([%{"role" => "user", "content" => "loop"}], [tool],
          generate_fn: generate_fn,
          max_rounds: 3
        )

      assert text == "Max tool rounds reached"
    end

    test "uses default max rounds of 20" do
      call_counter = :counters.new(1, [:atomics])

      generate_fn = fn model, context, opts ->
        :counters.add(call_counter, 1, 1)
        tool_call_response([{"ping", %{message: "x"}}]).(model, context, opts)
      end

      tool =
        make_tool("ping", "Ping", fn _args ->
          {:ok, Jason.encode!(%{pong: true})}
        end)

      {:ok, text, _ctx} =
        AgentLoop.run([%{"role" => "user", "content" => "loop"}], [tool],
          generate_fn: generate_fn
        )

      assert text == "Max tool rounds reached"
      # Should have called generate_fn exactly 20 times (rounds 1-20)
      assert :counters.get(call_counter, 1) == 20
    end
  end

  describe "LLM errors" do
    test "returns {:error, reason} when LLM fails" do
      generate_fn = fn _model, _context, _opts ->
        {:error, %{status: 429, body: "rate limited"}}
      end

      result = AgentLoop.run([%{"role" => "user", "content" => "hi"}], [],
        generate_fn: generate_fn
      )

      assert {:error, %{status: 429}} = result
    end

    test "LLM error mid-loop (after successful tool round) returns error" do
      tool =
        make_tool("ok_tool", "Works fine", fn _args ->
          {:ok, Jason.encode!(%{ok: true})}
        end)

      generate_fn =
        sequenced_generate([
          tool_call_response([{"ok_tool", %{message: "first"}}]),
          {:error, :timeout}
        ])

      result =
        AgentLoop.run([%{"role" => "user", "content" => "go"}], [tool],
          generate_fn: generate_fn
        )

      assert {:error, :timeout} = result
    end
  end

  describe "opts passthrough" do
    test "passes model to generate_fn" do
      captured = :ets.new(:captured_model, [:set, :public])

      generate_fn = fn model, _context, _opts ->
        :ets.insert(captured, {:model, model})
        text_response("ok")
      end

      AgentLoop.run([%{"role" => "user", "content" => "hi"}], [],
        generate_fn: generate_fn,
        model: "anthropic:claude-3-haiku"
      )

      [{:model, model}] = :ets.lookup(captured, :model)
      assert model == "anthropic:claude-3-haiku"
    end

    test "defaults model to openai:gpt-5-mini" do
      captured = :ets.new(:captured_default, [:set, :public])

      generate_fn = fn model, _context, _opts ->
        :ets.insert(captured, {:model, model})
        text_response("ok")
      end

      AgentLoop.run([%{"role" => "user", "content" => "hi"}], [],
        generate_fn: generate_fn
      )

      [{:model, model}] = :ets.lookup(captured, :model)
      assert model == "openai:gpt-5-mini"
    end

    test "passes tools list to generate_fn via opts" do
      captured = :ets.new(:captured_tools, [:set, :public])

      tool = make_tool("my_tool", "A tool", fn _args -> {:ok, "ok"} end)

      generate_fn = fn _model, _context, opts ->
        :ets.insert(captured, {:tools, opts[:tools]})
        text_response("ok")
      end

      AgentLoop.run([%{"role" => "user", "content" => "hi"}], [tool],
        generate_fn: generate_fn
      )

      [{:tools, tools}] = :ets.lookup(captured, :tools)
      assert length(tools) == 1
      assert hd(tools).name == "my_tool"
    end

    test "sets thread_id in process dictionary" do
      captured = :ets.new(:captured_thread, [:set, :public])

      generate_fn = fn _model, _context, _opts ->
        :ets.insert(captured, {:thread_id, Process.get(:hl7toagent_thread_id)})
        text_response("ok")
      end

      AgentLoop.run([%{"role" => "user", "content" => "hi"}], [],
        generate_fn: generate_fn,
        thread_id: "thread_abc"
      )

      [{:thread_id, tid}] = :ets.lookup(captured, :thread_id)
      assert tid == "thread_abc"
    end

    test "sets channel label in process dictionary" do
      captured = :ets.new(:captured_label, [:set, :public])

      generate_fn = fn _model, _context, _opts ->
        :ets.insert(captured, {:label, Process.get(:hl7toagent_channel)})
        text_response("ok")
      end

      AgentLoop.run([%{"role" => "user", "content" => "hi"}], [],
        generate_fn: generate_fn,
        label: "intake"
      )

      [{:label, label}] = :ets.lookup(captured, :label)
      assert label == "intake"
    end
  end

  describe "context threading" do
    test "final context contains all messages from the conversation" do
      tool =
        make_tool("echo", "Echo", fn args ->
          {:ok, Jason.encode!(%{echoed: args["message"]})}
        end)

      generate_fn =
        sequenced_generate([
          tool_call_response([{"echo", %{message: "ping"}}]),
          fn _m, context, _o ->
            # Return a response that carries the full context forward
            text_response_with_context("All done.", context)
          end
        ])

      {:ok, _text, final_ctx} =
        AgentLoop.run([%{"role" => "user", "content" => "echo ping"}], [tool],
          generate_fn: generate_fn
        )

      roles =
        Enum.map(final_ctx.messages, fn
          %Message{role: role} -> role
          %{"role" => role} -> String.to_existing_atom(role)
        end)

      # Should have: user, assistant (with tool call), tool result, assistant (final)
      assert :user in roles
      assert :assistant in roles
      assert :tool in roles
    end
  end

  describe "tool with typed params" do
    test "passes validated params to tool callback" do
      captured = :ets.new(:captured_params, [:set, :public])

      tool =
        make_tool(
          "adder",
          "Add numbers",
          [
            a: [type: :integer, required: true, doc: "First"],
            b: [type: :integer, required: true, doc: "Second"]
          ],
          fn args ->
            :ets.insert(captured, {:args, args})
            {:ok, Jason.encode!(%{sum: args["a"] + args["b"]})}
          end
        )

      generate_fn =
        sequenced_generate([
          tool_call_response([{"adder", %{a: 3, b: 4}}]),
          fn _m, _c, _o -> text_response("Sum is 7.") end
        ])

      {:ok, text, _ctx} =
        AgentLoop.run([%{"role" => "user", "content" => "add 3+4"}], [tool],
          generate_fn: generate_fn
        )

      assert text == "Sum is 7."
      [{:args, args}] = :ets.lookup(captured, :args)
      assert args[:a] == 3
      assert args[:b] == 4
    end
  end
end
