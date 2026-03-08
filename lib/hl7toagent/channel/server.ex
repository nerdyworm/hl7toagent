defmodule Hl7toagent.Channel.Server do
  use GenServer

  require Logger

  alias Hl7toagent.Channel.{AgentLoop, BuiltinSkill, ThreadStore, Pipeline}

  def start_link(channel_spec) do
    GenServer.start_link(__MODULE__, channel_spec,
      name: {:via, Registry, {Hl7toagent.ChannelRegistry, channel_spec.name}}
    )
  end

  @doc """
  Process a message, optionally continuing an existing thread.

  Options:
    - thread_id: resume an existing thread
    - thread_ref: look up thread by reference (e.g. email In-Reply-To)
  """
  def process_message(channel_name, raw_data, opts \\ []) do
    GenServer.call(
      {:via, Registry, {Hl7toagent.ChannelRegistry, channel_name}},
      {:process, raw_data, opts},
      600_000
    )
  end

  @impl true
  def init(channel_spec) do
    Logger.info("Starting channel: #{channel_spec.name}")

    skills = Enum.map(channel_spec.skills, &load_skill/1)
    tools = Enum.map(skills, & &1.tool)
    soul = load_soul(channel_spec.soul)

    {:ok,
     %{
       name: channel_spec.name,
       channel_spec: channel_spec,
       tools: tools,
       system_prompt: soul,
       model: channel_spec[:model]
     }}
  end

  @impl true
  def handle_call({:process, raw_data, opts}, _from, state) do
    {user_content, processing_path} = format_message(raw_data)

    thread_id = resolve_thread_id(opts)

    {messages, thread_id} =
      case thread_id do
        nil ->
          # New thread — start fresh
          msgs = build_messages(state.system_prompt, user_content)
          {:ok, tid} = ThreadStore.create_thread(state.name, msgs)
          {msgs, tid}

        tid ->
          # Existing thread — append new user message
          case ThreadStore.get_thread(tid) do
            {:ok, %{messages: prev_messages}} ->
              msgs = prev_messages ++ [%{"role" => "user", "content" => user_content}]
              {msgs, tid}

            {:error, :not_found} ->
              Logger.warning("[#{state.name}] Thread #{tid} not found, starting fresh")
              msgs = build_messages(state.system_prompt, user_content)
              {:ok, new_tid} = ThreadStore.create_thread(state.name, msgs)
              {msgs, new_tid}
          end
      end

    # Convert stored message maps to ReqLLM context
    context = messages_to_context(messages)

    llm_opts =
      [label: state.name, thread_id: thread_id] ++
        if(state.model, do: [model: state.model], else: [])

    result =
      case AgentLoop.run(context, state.tools, llm_opts) do
        {:ok, text, final_context} ->
          # Persist the full conversation for future continuation
          ThreadStore.update_thread(thread_id, context_to_messages(final_context))
          {:ok, %{text: text, thread_id: thread_id}}

        {:error, reason} ->
          {:error, reason}
      end

    if processing_path do
      project_dir = Application.get_env(:hl7toagent, :project_dir, File.cwd!())
      Pipeline.archive(processing_path, project_dir)
    end

    {:reply, result, state}
  end

  # Support old-style calls without opts
  def handle_call({:process, raw_data}, from, state) do
    handle_call({:process, raw_data, []}, from, state)
  end

  defp format_message({:file, path, contents}) do
    {"""
     New file arrived: #{Path.basename(path)}

     Contents:
     #{contents}

     Use your available tools to handle it appropriately.
     """, path}
  end

  defp format_message(text) do
    {"""
     Process this incoming message:

     #{text}

     Use your available tools to handle it appropriately.
     """, nil}
  end

  defp resolve_thread_id(opts) do
    cond do
      opts[:thread_id] ->
        opts[:thread_id]

      opts[:thread_ref] ->
        case ThreadStore.find_by_ref(opts[:thread_ref]) do
          {:ok, tid} -> tid
          {:error, :not_found} -> nil
        end

      true ->
        nil
    end
  end

  defp build_messages(nil, user_content) do
    [%{"role" => "user", "content" => user_content}]
  end

  defp build_messages(system_prompt, user_content) do
    [
      %{"role" => "system", "content" => system_prompt},
      %{"role" => "user", "content" => user_content}
    ]
  end

  defp messages_to_context(messages) do
    msgs =
      messages
      |> Enum.filter(fn msg -> msg["role"] in ["system", "user", "assistant"] end)
      |> Enum.map(fn
        %{"role" => "system", "content" => c} -> ReqLLM.Context.system(extract_text(c))
        %{"role" => "user", "content" => c} -> ReqLLM.Context.user(extract_text(c))
        %{"role" => "assistant", "content" => c} -> ReqLLM.Context.assistant(extract_text(c))
      end)

    ReqLLM.Context.new(msgs)
  end

  defp extract_text(content) when is_binary(content), do: content
  defp extract_text([%{"text" => text} | _]), do: text
  defp extract_text(_), do: ""

  defp context_to_messages(context) do
    # Only persist system/user/assistant text turns — skip tool calls/results
    # which contain internal ReqLLM structures that don't round-trip through JSON
    context.messages
    |> Enum.filter(fn msg ->
      role = to_string(msg.role)
      role in ["system", "user", "assistant"]
    end)
    |> Enum.map(fn msg ->
      content =
        case msg.content do
          text when is_binary(text) -> text
          [%{text: text} | _] -> text
          [%{"text" => text} | _] -> text
          other -> inspect(other)
        end

      %{"role" => to_string(msg.role), "content" => content}
    end)
  end

  defp load_skill("builtin:" <> name), do: BuiltinSkill.load!(name)
  defp load_skill(path), do: Hl7toagent.Channel.Skill.load_skill!(path)

  defp load_soul(nil), do: nil

  defp load_soul(path) do
    case File.read(path) do
      {:ok, content} ->
        content

      {:error, _} ->
        Logger.warning("Could not read soul file: #{path}")
        nil
    end
  end
end
