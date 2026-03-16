defmodule Hl7toagent.Channel.SkillTest do
  use ExUnit.Case, async: true

  alias Hl7toagent.Channel.Skill

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "hl7toagent_skill_#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  defp write_skill(dir, filename, lua_source) do
    path = Path.join(dir, filename)
    File.write!(path, lua_source)
    path
  end

  describe "load_skill!/1 basic tool" do
    test "loads a simple skill with explicit params", %{tmp_dir: dir} do
      path = write_skill(dir, "greet.lua", """
      return {
        name = "greet",
        description = "Say hello to someone",
        params = {
          name = { type = "string", required = true, doc = "Person's name" }
        },
        run = function(params)
          return { greeting = "Hello, " .. params.name }
        end
      }
      """)

      skill = Skill.load_skill!(path)

      assert skill.name == "greet"
      assert skill.description == "Say hello to someone"
      assert skill.kind == :tool
      assert skill.path == Path.expand(path)
      assert %ReqLLM.Tool{} = skill.tool
    end

    test "loads a skill with default message param when params omitted", %{tmp_dir: dir} do
      path = write_skill(dir, "echo.lua", """
      return {
        name = "echo",
        description = "Echo back",
        run = function(params)
          return { message = params.message }
        end
      }
      """)

      skill = Skill.load_skill!(path)
      assert skill.name == "echo"
      assert skill.kind == :tool
    end

    test "loads a skill with multiple params of different types", %{tmp_dir: dir} do
      path = write_skill(dir, "multi.lua", """
      return {
        name = "multi",
        description = "Multi-param skill",
        params = {
          text = { type = "string", required = true, doc = "Text input" },
          count = { type = "integer", required = false, doc = "Repeat count" },
          flag = { type = "boolean", required = false, doc = "A flag" }
        },
        run = function(params)
          return { ok = true }
        end
      }
      """)

      skill = Skill.load_skill!(path)
      assert skill.name == "multi"
      assert skill.kind == :tool
    end
  end

  describe "load_skill!/1 agent skill" do
    test "detects agent kind when soul field is present", %{tmp_dir: dir} do
      path = write_skill(dir, "agent.lua", """
      return {
        name = "sub_agent",
        description = "A sub-agent skill",
        soul = "agent_soul.md",
        skills = { "greet.lua" },
        params = {
          task = { type = "string", required = true, doc = "Task to do" }
        }
      }
      """)

      skill = Skill.load_skill!(path)
      assert skill.name == "sub_agent"
      assert skill.kind == :agent
    end
  end

  describe "load_skill!/1 error handling" do
    test "parse error raises on invalid Lua syntax", %{tmp_dir: dir} do
      path = write_skill(dir, "bad_syntax.lua", """
      return {{{
      """)

      assert_raise Lua.CompilerException, fn ->
        Skill.load_skill!(path)
      end
    end

    test "missing file raises", %{tmp_dir: dir} do
      assert_raise File.Error, fn ->
        Skill.load_skill!(Path.join(dir, "nonexistent.lua"))
      end
    end

    test "skill missing name field raises validation error", %{tmp_dir: dir} do
      path = write_skill(dir, "no_name.lua", """
      return {
        description = "no name",
        run = function(params) return {} end
      }
      """)

      # ReqLLM.Tool validates name is required
      assert_raise ReqLLM.Error.Validation.Error, fn ->
        Skill.load_skill!(path)
      end
    end

    test "skill missing run field loads as tool kind", %{tmp_dir: dir} do
      path = write_skill(dir, "no_run.lua", """
      return {
        name = "no_run",
        description = "has no run function"
      }
      """)

      # No soul → kind is :tool, but run is nil. load_skill! succeeds
      # because it just wraps a callback — the error surfaces at execute time.
      skill = Skill.load_skill!(path)
      assert skill.kind == :tool
      assert skill.name == "no_run"
    end

    test "skill returning non-table raises", %{tmp_dir: dir} do
      path = write_skill(dir, "returns_string.lua", """
      return "not a table"
      """)

      # Lua.call_function! on rawget expects a table — raises RuntimeException
      assert_raise Lua.RuntimeException, fn ->
        Skill.load_skill!(path)
      end
    end

    test "empty file raises", %{tmp_dir: dir} do
      path = write_skill(dir, "empty.lua", "")

      assert_raise MatchError, fn ->
        Skill.load_skill!(path)
      end
    end
  end

  describe "execute/2 error messages" do
    test "parse error includes filename and line number", %{tmp_dir: dir} do
      Application.put_env(:hl7toagent, :project_dir, dir)

      path = write_skill(dir, "bad_parse.lua", """
      return {{{
      """)

      {:ok, json} = Skill.execute(path, %{message: "test"})
      result = Jason.decode!(json)
      assert result["error"] =~ "bad_parse.lua"
      assert result["error"] =~ "syntax error"
    end

    test "parse error on later line includes correct line number", %{tmp_dir: dir} do
      Application.put_env(:hl7toagent, :project_dir, dir)

      path = write_skill(dir, "late_parse.lua", """
      return {
        name = "x",
        description = "x",
        run = function(params)
          local x = {
          return x
        end
      }
      """)

      {:ok, json} = Skill.execute(path, %{message: "test"})
      result = Jason.decode!(json)
      assert result["error"] =~ "late_parse.lua"
      assert result["error"] =~ "line 6"
    end

    test "runtime error() shows the message clearly", %{tmp_dir: dir} do
      Application.put_env(:hl7toagent, :project_dir, dir)

      path = write_skill(dir, "runtime_err.lua", """
      return {
        name = "rt", description = "x",
        run = function(params)
          error("patient ID is missing")
        end
      }
      """)

      {:ok, json} = Skill.execute(path, %{message: "test"})
      result = Jason.decode!(json)
      assert result["error"] =~ "runtime_err.lua"
      assert result["error"] =~ "patient ID is missing"
      # Should NOT contain raw Erlang tuple syntax
      refute result["error"] =~ ":error_call"
    end

    test "undefined function names the function", %{tmp_dir: dir} do
      Application.put_env(:hl7toagent, :project_dir, dir)

      path = write_skill(dir, "undef.lua", """
      return {
        name = "uf", description = "x",
        run = function(params)
          return do_something(params.message)
        end
      }
      """)

      {:ok, json} = Skill.execute(path, %{message: "test"})
      result = Jason.decode!(json)
      assert result["error"] =~ "undef.lua"
      # Should say something about calling a nil value, not "undefined function: nil"
      assert result["error"] =~ ~r/nil|not a function/i
    end

    test "nil field access explains what happened", %{tmp_dir: dir} do
      Application.put_env(:hl7toagent, :project_dir, dir)

      path = write_skill(dir, "nil_index.lua", """
      return {
        name = "ni", description = "x",
        run = function(params)
          local t = nil
          return { result = t.field }
        end
      }
      """)

      {:ok, json} = Skill.execute(path, %{message: "test"})
      result = Jason.decode!(json)
      assert result["error"] =~ "nil_index.lua"
      assert result["error"] =~ "field"
      # Should NOT contain raw Erlang tuple syntax
      refute result["error"] =~ ":illegal_index"
    end

    test "missing file includes filename", %{tmp_dir: dir} do
      Application.put_env(:hl7toagent, :project_dir, dir)

      {:ok, json} = Skill.execute(Path.join(dir, "gone.lua"), %{message: "test"})
      result = Jason.decode!(json)
      assert result["error"] =~ "gone.lua"
      assert result["error"] =~ ~r/not found|no such file/i
    end

    test "skill with no run function gives clear message", %{tmp_dir: dir} do
      Application.put_env(:hl7toagent, :project_dir, dir)

      path = write_skill(dir, "no_run.lua", """
      return {
        name = "no_run",
        description = "missing run"
      }
      """)

      {:ok, json} = Skill.execute(path, %{message: "test"})
      result = Jason.decode!(json)
      assert result["error"] =~ "no_run.lua"
    end

    test "run function that returns nil produces empty JSON", %{tmp_dir: dir} do
      Application.put_env(:hl7toagent, :project_dir, dir)

      path = write_skill(dir, "nil_return.lua", """
      return {
        name = "nil_return",
        description = "returns nothing",
        run = function(params)
          -- no return
        end
      }
      """)

      {:ok, json} = Skill.execute(path, %{message: "test"})
      result = Jason.decode!(json)
      assert result == %{}
    end
  end

  describe "execute/2 tool execution" do
    test "executes a simple Lua skill and returns JSON", %{tmp_dir: dir} do
      Application.put_env(:hl7toagent, :project_dir, dir)

      path = write_skill(dir, "adder.lua", """
      return {
        name = "adder",
        description = "Add two numbers",
        params = {
          a = { type = "number", required = true, doc = "First number" },
          b = { type = "number", required = true, doc = "Second number" }
        },
        run = function(params)
          return { sum = params.a + params.b }
        end
      }
      """)

      {:ok, json} = Skill.execute(path, %{a: 3, b: 4})
      result = Jason.decode!(json)
      assert result["sum"] == 7.0
    end

    test "skill can use file.write and file.read", %{tmp_dir: dir} do
      Application.put_env(:hl7toagent, :project_dir, dir)

      path = write_skill(dir, "filetest.lua", """
      return {
        name = "filetest",
        description = "Test file ops",
        params = {
          content = { type = "string", required = true, doc = "Content to write" }
        },
        run = function(params)
          file.write("test_output.txt", params.content)
          local read_back = file.read("test_output.txt")
          return { written = true, read_back = read_back }
        end
      }
      """)

      {:ok, json} = Skill.execute(path, %{content: "hello from lua"})
      result = Jason.decode!(json)
      assert result["written"] == true
      assert result["read_back"] == "hello from lua"
      assert File.read!(Path.join(dir, "test_output.txt")) == "hello from lua"
    end

    test "skill error returns JSON error instead of crashing", %{tmp_dir: dir} do
      Application.put_env(:hl7toagent, :project_dir, dir)

      path = write_skill(dir, "bad.lua", """
      return {
        name = "bad",
        description = "A broken skill",
        run = function(params)
          error("something went wrong")
        end
      }
      """)

      {:ok, json} = Skill.execute(path, %{message: "test"})
      assert json =~ "something went wrong"
    end

    test "skill calling undefined function returns error", %{tmp_dir: dir} do
      Application.put_env(:hl7toagent, :project_dir, dir)

      path = write_skill(dir, "undef.lua", """
      return {
        name = "undef",
        description = "Calls undefined function",
        run = function(params)
          return nonexistent_function()
        end
      }
      """)

      {:ok, json} = Skill.execute(path, %{message: "test"})
      assert json =~ "error"
    end
  end
end
