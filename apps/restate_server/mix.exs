defmodule Restate.Server.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/adamnoonan/restate-elixir"

  def project do
    [
      app: :restate_server,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs(),
      name: "Restate"
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Restate.Server.Application, []}
    ]
  end

  # The protocol dep is in-umbrella for normal dev (so `mix test`
  # picks up local changes) and a hex version constraint at publish
  # time. Toggle via the `RESTATE_HEX_PUBLISH` env var — set it when
  # running `mix hex.build` / `hex.publish` so the package declares
  # the protocol as a hex dep rather than an unpublishable umbrella
  # sibling. See `docs/release.md` for the publish runbook.
  defp deps do
    protocol_dep =
      if System.get_env("RESTATE_HEX_PUBLISH") do
        {:restate_protocol, "~> #{@version}"}
      else
        {:restate_protocol, in_umbrella: true}
      end

    [
      protocol_dep,
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Elixir SDK for Restate — a durable execution runtime. Implements service protocol V5 (Service / VirtualObject / Workflow) with cancellation, awaitable combinators, ctx.run retry policies, durable promises, and lazy state. 49/49 sdk-test-suite conformance tests passing."
  end

  defp package do
    [
      licenses: ["MIT"],
      maintainers: ["Adam Noonan <adam@samachi.com>"],
      links: %{
        "GitHub" => @source_url,
        "Restate" => "https://restate.dev",
        "Conformance" => "https://github.com/restatedev/sdk-test-suite"
      },
      files: ~w(lib mix.exs README.md ../../LICENSE ../../CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md": [title: "README"], "../../CHANGELOG.md": [title: "Changelog"]],
      source_ref: "v#{@version}",
      groups_for_modules: [
        "User-facing API": [Restate.Context, Restate.Awaitable, Restate.RetryPolicy, Restate.TerminalError, Restate.ProtocolError],
        "Server runtime": [Restate.Server.Application, Restate.Server.Endpoint, Restate.Server.Registry, Restate.Server.DrainCoordinator, Restate.Server.Manifest],
        "Internals": [Restate.Server.Invocation]
      ]
    ]
  end
end
