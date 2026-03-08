defmodule Hl7toagent.Lua.FileApi do
  use Lua.API, scope: "file"

  deflua read(path), state do
    sandbox_dir = Lua.get_private!(state, :sandbox_dir)
    safe_path = resolve_safe_path!(sandbox_dir, path)

    case File.read(safe_path) do
      {:ok, content} -> {[content], state}
      {:error, reason} -> {[nil, to_string(reason)], state}
    end
  end

  deflua write(path, content), state do
    sandbox_dir = Lua.get_private!(state, :sandbox_dir)
    safe_path = resolve_safe_path!(sandbox_dir, path)
    File.mkdir_p!(Path.dirname(safe_path))

    case File.write(safe_path, content) do
      :ok -> {[true], state}
      {:error, reason} -> {[nil, to_string(reason)], state}
    end
  end

  deflua append(path, content), state do
    sandbox_dir = Lua.get_private!(state, :sandbox_dir)
    safe_path = resolve_safe_path!(sandbox_dir, path)
    case File.write(safe_path, content, [:append]) do
      :ok -> {[true], state}
      {:error, reason} -> {[nil, to_string(reason)], state}
    end
  end

  deflua delete(path), state do
    sandbox_dir = Lua.get_private!(state, :sandbox_dir)
    safe_path = resolve_safe_path!(sandbox_dir, path)

    case File.rm(safe_path) do
      :ok -> {[true], state}
      {:error, reason} -> {[nil, to_string(reason)], state}
    end
  end

  deflua move(source, destination), state do
    sandbox_dir = Lua.get_private!(state, :sandbox_dir)
    safe_source = resolve_safe_path!(sandbox_dir, source)
    safe_dest = resolve_safe_path!(sandbox_dir, destination)
    File.mkdir_p!(Path.dirname(safe_dest))

    case File.rename(safe_source, safe_dest) do
      :ok -> {[true], state}
      {:error, reason} -> {[nil, to_string(reason)], state}
    end
  end

  deflua list(path), state do
    sandbox_dir = Lua.get_private!(state, :sandbox_dir)
    safe_path = resolve_safe_path!(sandbox_dir, path)

    case File.ls(safe_path) do
      {:ok, entries} ->
        {result, state} = Lua.encode!(state, entries)
        {[result], state}

      {:error, reason} ->
        {[nil, to_string(reason)], state}
    end
  end

  defp resolve_safe_path!(sandbox_dir, path) do
    # Strip leading slashes so "/inbox/foo" becomes "inbox/foo" relative to sandbox
    clean_path = String.trim_leading(path, "/")
    expanded = Path.expand(clean_path, sandbox_dir)

    unless String.starts_with?(expanded, Path.expand(sandbox_dir)) do
      raise "Path traversal attempt: #{path}"
    end

    expanded
  end
end
