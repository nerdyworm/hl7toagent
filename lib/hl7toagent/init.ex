defmodule Hl7toagent.Init do
  @moduledoc """
  Interactive project scaffolder. Uses an LLM agent to guide the user
  through setting up a new hl7toagent project via stdin/stdout.
  """

  @model "openai:gpt-5-mini"
  @max_rounds 30

  @soul """
  You are the hl7toagent project setup assistant. You help users create new integration projects.

  An hl7toagent project is a directory containing:
  - `config.lua` — defines channels (data pipelines)
  - `souls/` — markdown system prompts that give each channel its personality and rules
  - `skills/` — Lua scripts that define tools the channel agent can use

  Each channel has:
  - A **source** — where data comes in: `mllp` (HL7 v2 over TCP), `http` (POST endpoint), or `file_watcher` (monitor a directory)
  - A **soul** — a markdown file that tells the agent what it is and how to handle messages
  - **Skills** — Lua tool scripts the agent can call (send webhooks, write files, transform data, etc.)

  ## Your job

  Guide the user through creating their project. Ask questions to understand:
  1. What kind of data are they receiving? (HL7 feeds, HTTP webhooks, files dropping in a folder?)
  2. What should happen with the data? (Forward to a webhook? Transform to FHIR? Log it? Route by message type?)
  3. Any specific rules or validation? (Required fields, routing logic, error handling?)

  Be conversational and helpful. Ask one or two questions at a time, not a huge list.
  Just talk to the user directly — your text responses are shown to them and they can reply.

  Once you understand what they need, use the write_file tool to create:
  - `config.lua` with their channel definitions
  - Soul files in `souls/` with appropriate system prompts
  - Skill files in `skills/` with Lua tool implementations

  ## Available skill APIs

  Skills have access to these built-in Lua APIs:
  - `http.get(url, opts)` / `http.post(url, opts)` — make HTTP requests. opts can have `headers` and `body`.
  - `file.write(filename, content)` / `file.read(filename)` — read/write files in the sandbox directory

  ## config.lua format

  ```lua
  channel("channel_name", {
      source = mllp({ port = 2575 }),
      -- or: source = http({ port = 4000, path = "/webhook" }),
      -- or: source = file_watcher({ dir = "./inbox", pattern = "*.hl7" }),
      soul = "souls/my_soul.md",
      skills = { "skills/my_skill.lua" }
  })
  ```

  ## Skill file format

  ```lua
  return {
    name = "skill_name",
    description = "What this tool does — the LLM reads this to decide when to use it",
    params = {
      param_name = { type = "string", required = true, doc = "Description" }
    },
    run = function(params)
      -- do work here
      return { status = "ok" }
    end
  }
  ```

  If params is omitted, the skill gets a single `message` string parameter by default.

  ## Important

  - Write practical, working code — not placeholders or stubs.
  - After writing all files, give a brief summary of what was created and how to run it.
  - Keep soul prompts focused and specific to the user's actual use case.
  - ALWAYS use the write_file tool to create files. Never paste file contents for the user to copy manually.
  - You can use read_file to check what you've already written.
  - If a write_file call fails, check the error and retry — don't give up and dump instructions.
  - You can also create extra directories the project needs (like inbox/, archive/) by writing a placeholder or just by writing files into subdirectories.
  """

  def run(project_dir) do
    File.mkdir_p!(project_dir)
    File.mkdir_p!(Path.join(project_dir, "souls"))
    File.mkdir_p!(Path.join(project_dir, "skills"))

    {:ok, _} = Application.ensure_all_started(:req_llm)

    # Quiet the logger so the conversation is readable
    Logger.configure(level: :warning)

    IO.puts("\nhl7toagent project setup")
    IO.puts("========================\n")

    tools = [
      write_file_tool(project_dir),
      read_file_tool(project_dir),
      create_directory_tool(project_dir),
      list_files_tool(project_dir)
    ]

    messages = [
      ReqLLM.Context.system(@soul),
      ReqLLM.Context.user(
        "I want to set up a new hl7toagent project in #{project_dir}. Help me get started."
      )
    ]

    context = ReqLLM.Context.new(messages)
    conversation_loop(context, tools, 1)

    IO.puts("\nProject ready in #{project_dir}")
    IO.puts("Run with: hl7toagent start #{project_dir}\n")
  end

  defp conversation_loop(_context, _tools, round) when round > @max_rounds do
    IO.puts("\n(max rounds reached)")
  end

  defp conversation_loop(context, tools, round) do
    case ReqLLM.generate_text(@model, context, tools: tools) do
      {:ok, response} ->
        tool_calls = ReqLLM.Response.tool_calls(response)

        if tool_calls == [] do
          # Text response — show it to the user, prompt for reply
          text = ReqLLM.Response.text(response)

          if text do
            IO.puts("\n#{text}")

            answer = IO.gets("\n> ") |> String.trim()

            if answer in ["", "done", "exit", "quit"] do
              :ok
            else
              updated =
                ReqLLM.Context.append(
                  response.context,
                  ReqLLM.Context.user(answer)
                )

              conversation_loop(updated, tools, round + 1)
            end
          end
        else
          # Tool calls — execute them silently, continue
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

          conversation_loop(updated_context, tools, round + 1)
        end

      {:error, reason} ->
        IO.puts("\nError: #{inspect(reason)}")
    end
  end

  defp write_file_tool(project_dir) do
    ReqLLM.tool(
      name: "write_file",
      description:
        "Write a file to the project directory. Creates parent directories automatically. Use relative paths like 'config.lua', 'souls/router.md', 'skills/webhook.lua'.",
      parameter_schema: [
        path: [type: :string, required: true, doc: "Relative path within the project directory"],
        content: [type: :string, required: true, doc: "File content to write"]
      ],
      callback: fn args ->
        path = args["path"] || args[:path]
        content = args["content"] || args[:content]

        full_path = Path.join(project_dir, path)

        try do
          File.mkdir_p!(Path.dirname(full_path))
          File.write!(full_path, content)
          IO.puts("  wrote #{path}")
          {:ok, Jason.encode!(%{status: "ok", path: path, bytes: byte_size(content)})}
        rescue
          e ->
            IO.puts("  error writing #{path}: #{Exception.message(e)}")
            {:ok, Jason.encode!(%{status: "error", error: Exception.message(e), path: path})}
        end
      end
    )
  end

  defp read_file_tool(project_dir) do
    ReqLLM.tool(
      name: "read_file",
      description: "Read the contents of a file in the project directory.",
      parameter_schema: [
        path: [type: :string, required: true, doc: "Relative path within the project directory"]
      ],
      callback: fn args ->
        path = args["path"] || args[:path]
        full_path = Path.join(project_dir, path)

        case File.read(full_path) do
          {:ok, content} ->
            {:ok, Jason.encode!(%{status: "ok", path: path, content: content})}

          {:error, reason} ->
            {:ok, Jason.encode!(%{status: "error", error: inspect(reason), path: path})}
        end
      end
    )
  end

  defp create_directory_tool(project_dir) do
    ReqLLM.tool(
      name: "create_directory",
      description:
        "Create a directory in the project. Use for directories the project needs at runtime, like 'inbox/' or 'archive/'.",
      parameter_schema: [
        path: [type: :string, required: true, doc: "Relative directory path to create"]
      ],
      callback: fn args ->
        path = args["path"] || args[:path]
        full_path = Path.join(project_dir, path)

        try do
          File.mkdir_p!(full_path)
          IO.puts("  created #{path}/")
          {:ok, Jason.encode!(%{status: "ok", path: path})}
        rescue
          e ->
            IO.puts("  error creating #{path}/: #{Exception.message(e)}")
            {:ok, Jason.encode!(%{status: "error", error: Exception.message(e), path: path})}
        end
      end
    )
  end

  defp list_files_tool(project_dir) do
    ReqLLM.tool(
      name: "list_files",
      description: "List files already in the project directory.",
      parameter_schema: [],
      callback: fn _args ->
        files =
          Path.wildcard(Path.join(project_dir, "**/*"))
          |> Enum.filter(&File.regular?/1)
          |> Enum.map(&Path.relative_to(&1, project_dir))

        {:ok, Jason.encode!(%{files: files})}
      end
    )
  end
end
