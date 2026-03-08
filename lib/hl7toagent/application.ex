defmodule Hl7toagent.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    unless Application.get_env(:hl7toagent, :start_channels, true) do
      Supervisor.start_link([], strategy: :one_for_one, name: Hl7toagent.Supervisor)
    else
      case resolve_command() do
        {:init, dir} ->
          Hl7toagent.Init.run(dir)
          System.halt(0)

        {:start, project_dir} ->
          Application.put_env(:hl7toagent, :project_dir, project_dir)
          start_channels(project_dir)
      end
    end
  end

  defp start_channels(project_dir) do
    config_path = Path.join(project_dir, "config.lua")

    unless File.exists?(config_path) do
      IO.puts("Error: no config.lua found in #{project_dir}")
      System.halt(1)
    end

    Logger.info("Starting hl7toagent in #{project_dir}")

    {channels, crons} = Hl7toagent.ConfigLoader.load_config!(config_path, project_dir)
    Logger.info("Loaded #{length(channels)} channel(s), #{length(crons)} cron(s)")

    channel_children =
      Enum.map(channels, fn spec ->
        Supervisor.child_spec(
          {Hl7toagent.Channel.Supervisor, spec},
          id: :"channel_#{spec.name}"
        )
      end)

    cron_children =
      Enum.map(crons, fn spec ->
        Hl7toagent.Cron.Runner.child_spec(spec)
      end)

    children =
      [
        {Registry, keys: :unique, name: Hl7toagent.ChannelRegistry},
        {Hl7toagent.Channel.ThreadStore, project_dir: project_dir}
      ] ++ channel_children ++ cron_children

    opts = [strategy: :one_for_one, name: Hl7toagent.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp resolve_command do
    argv =
      if Code.ensure_loaded?(Burrito.Util.Args) do
        Burrito.Util.Args.argv()
      else
        []
      end

    case argv do
      ["init", dir | _] -> {:init, Path.expand(dir)}
      ["init"] -> {:init, File.cwd!()}
      ["start", dir | _] -> {:start, Path.expand(dir)}
      ["start"] -> {:start, File.cwd!()}
      [] ->
        dir =
          System.get_env("HL7TOAGENT_PROJECT_DIR") ||
            Application.get_env(:hl7toagent, :project_dir) ||
            File.cwd!()

        {:start, Path.expand(dir)}
      _ ->
        IO.puts("""
        hl7toagent - give your data feeds a soul

        Usage:
          hl7toagent init [project_dir]    Set up a new project interactively
          hl7toagent start [project_dir]   Start processing channels

        The project directory should contain:
          config.lua    Channel definitions
          souls/        System prompts (markdown)
          skills/       Tool scripts (Lua)
        """)

        System.halt(0)
    end
  end
end
