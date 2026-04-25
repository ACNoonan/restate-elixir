defmodule RestateElixir.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  defp deps do
    []
  end

  defp releases do
    [
      restate_elixir: [
        # Boot the example greeter; it depends on restate_server which
        # depends on restate_protocol, so all three load.
        applications: [restate_example_greeter: :permanent],
        include_executables_for: [:unix]
      ]
    ]
  end
end
