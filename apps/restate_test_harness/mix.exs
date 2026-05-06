defmodule Restate.TestHarness.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/ACNoonan/restate-elixir"

  def project do
    [
      app: :restate_test_harness,
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
      name: "Restate.TestHarness"
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets],
      mod: {Restate.TestHarness.Application, []}
    ]
  end

  defp deps do
    [
      {:finch, "~> 0.20"},
      {:jason, "~> 1.4"},
      # Test-only: drives the example greeter through the harness in
      # the cross-app e2e test. Pulls in :restate_server transitively.
      {:restate_example_greeter, in_umbrella: true, only: :test, runtime: false}
    ]
  end

  defp description do
    "BEAM-aware integration test harness for the Restate Elixir SDK. Boots restate-server in Docker per test, registers an Elixir deployment, and drives invocations from ExUnit."
  end

  defp package do
    [
      licenses: ["MIT"],
      maintainers: ["Adam Noonan <adam@samachi.com>"],
      links: %{"GitHub" => @source_url, "Restate" => "https://restate.dev"},
      files: ~w(lib mix.exs ../../LICENSE)
    ]
  end
end
