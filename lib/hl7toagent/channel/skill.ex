defmodule Hl7toagent.Channel.Skill do
  @moduledoc """
  Loads Lua skill files and returns ReqLLM tools backed by Lua execution.
  """

  require Logger

  def load_skill!(path) do
    lua = Lua.new()
    {[skill_table], lua} = Lua.eval!(lua, File.read!(path), decode: false)

    {[name], _} = Lua.call_function!(lua, [:rawget], [skill_table, "name"])
    {[description], _} = Lua.call_function!(lua, [:rawget], [skill_table, "description"])
    params_schema = load_params_schema(lua, skill_table)

    abs_path = Path.expand(path)
    soul_path = load_string_field(lua, skill_table, "soul")
    sub_skill_paths = load_sub_skills(lua, skill_table)

    kind =
      cond do
        soul_path != nil -> :agent
        true -> :tool
      end

    callback =
      case kind do
        :agent ->
          fn args -> execute_agent(abs_path, soul_path, sub_skill_paths, args) end

        :tool ->
          fn args -> execute(abs_path, args) end
      end

    tool =
      ReqLLM.tool(
        name: name,
        description: description,
        parameter_schema: params_schema,
        callback: callback
      )

    %{name: name, description: description, tool: tool, path: abs_path, kind: kind}
  end

  @type_map %{
    "string" => :string,
    "number" => :number,
    "integer" => :integer,
    "boolean" => :boolean
  }

  defp load_params_schema(lua, skill_table) do
    case Lua.call_function!(lua, [:rawget], [skill_table, "params"]) do
      {[nil], _} ->
        [message: [type: :string, required: true, doc: "The message to process"]]

      {[{:tref, _} = tref], lua} ->
        params = lua |> Lua.decode!(tref) |> Lua.Table.deep_cast()

        Enum.map(params, fn {key, spec} when is_map(spec) ->
          type = Map.get(@type_map, Map.get(spec, "type", "string"), :string)
          required = Map.get(spec, "required", false)
          doc = Map.get(spec, "doc", "")
          {String.to_atom(key), [type: type, required: required, doc: doc]}
        end)
    end
  end

  defp load_string_field(lua, skill_table, field) do
    case Lua.call_function!(lua, [:rawget], [skill_table, field]) do
      {[nil], _} -> nil
      {[val], _} when is_binary(val) -> val
      _ -> nil
    end
  end

  defp load_sub_skills(lua, skill_table) do
    case Lua.call_function!(lua, [:rawget], [skill_table, "skills"]) do
      {[nil], _} ->
        []

      {[{:tref, _} = tref], lua} ->
        lua
        |> Lua.decode!(tref)
        |> Lua.Table.deep_cast()
        |> then(fn
          list when is_list(list) -> list
          map when is_map(map) -> Map.values(map)
        end)

      _ ->
        []
    end
  end

  def execute_agent(skill_path, soul_path, sub_skill_paths, params) do
    soul =
      case File.read(Path.expand(soul_path, Path.dirname(skill_path))) do
        {:ok, content} ->
          content

        {:error, _} ->
          Logger.warning("Agent skill: could not read soul #{soul_path}")
          nil
      end

    sub_skills =
      Enum.map(sub_skill_paths, fn sp ->
        resolved = Path.expand(sp, Path.dirname(skill_path))
        load_skill!(resolved)
      end)

    sub_tools = Enum.map(sub_skills, & &1.tool)

    user_content =
      params
      |> Enum.map(fn {k, v} -> "#{k}: #{v}" end)
      |> Enum.join("\n")

    messages = [ReqLLM.Context.user(user_content)]

    messages =
      if soul do
        [ReqLLM.Context.system(soul) | messages]
      else
        messages
      end

    skill_name = Path.basename(skill_path, ".lua")
    Logger.info("Spawning sub-agent skill: #{skill_name} (#{length(sub_tools)} sub-tools)")

    case Hl7toagent.Channel.AgentLoop.run(messages, sub_tools, label: "skill:#{skill_name}") do
      {:ok, text, _context} -> {:ok, Jason.encode!(%{result: text})}
      {:error, err} -> {:ok, Jason.encode!(%{error: inspect(err)})}
    end
  rescue
    e ->
      Logger.error(
        "Agent skill error: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
      )

      {:ok, Jason.encode!(%{error: Exception.message(e)})}
  end

  def execute(path, params) do
    project_dir = Application.get_env(:hl7toagent, :project_dir, File.cwd!())
    sandbox_dir = project_dir

    lua =
      Lua.new()
      |> Lua.put_private(:sandbox_dir, sandbox_dir)
      |> Lua.load_api(Hl7toagent.Lua.HttpApi)
      |> Lua.load_api(Hl7toagent.Lua.FileApi)
      |> Lua.load_api(Hl7toagent.Lua.EmailApi)

    {[skill_table], lua} = Lua.eval!(lua, File.read!(path), decode: false)
    {[run_ref], lua} = Lua.call_function!(lua, [:rawget], [skill_table, "run"])

    {params_table, lua} = Lua.encode!(lua, stringify_keys(params))

    {result, lua} =
      case Lua.call_function(lua, run_ref, [params_table]) do
        {:ok, result, lua} ->
          {result, lua}

        {:error, {:undefined_function, func}, lua} ->
          Logger.error("Lua undefined function: #{inspect(func)} in skill #{path}")
          {[Jason.encode!(%{error: "undefined function: #{inspect(func)}"})], lua}

        {:error, reason, lua} ->
          Logger.error("Lua error in skill #{path}: #{inspect(reason)}")
          {[Jason.encode!(%{error: inspect(reason)})], lua}
      end

    decoded =
      case result do
        [{:tref, _} = tref] -> deep_decode(lua, tref)
        [val] when is_list(val) -> Lua.Table.deep_cast(val)
        [val] -> val
        [] -> nil
      end

    {:ok, Jason.encode!(decoded || %{})}
  rescue
    e ->
      Logger.error(
        "Skill execution error: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
      )

      {:ok, Jason.encode!(%{error: Exception.message(e)})}
  end

  defp deep_decode(lua, {:tref, _} = tref) do
    lua
    |> Lua.decode!(tref)
    |> Enum.map(fn {k, v} -> {k, deep_decode(lua, v)} end)
    |> Lua.Table.deep_cast()
  end

  defp deep_decode(_lua, val), do: val

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
