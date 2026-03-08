defmodule Hl7toagent.MixProject do
  use Mix.Project

  def project do
    [
      app: :hl7toagent,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Hl7toagent.Application, []}
    ]
  end

  defp deps do
    [
      {:mllp, "~> 0.9"},
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      {:file_system, "~> 1.0"},
      {:req_llm, github: "agentjido/req_llm"},
      {:req, "~> 0.5"},
      {:lua, "~> 0.4"},
      {:burrito, "~> 1.0"},
      {:gen_smtp, "~> 1.2"},
      {:exqlite, "~> 0.27"},
      {:mailroom, path: "/home/ben/code/sable-mail/vendor/mailroom", override: true},
      {:mail, "~> 0.5"}
    ]
  end

  defp releases do
    [
      hl7toagent: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux: [os: :linux, cpu: :x86_64],
            macos: [os: :darwin, cpu: :x86_64],
            macos_arm: [os: :darwin, cpu: :aarch64]
          ]
        ]
      ]
    ]
  end
end
