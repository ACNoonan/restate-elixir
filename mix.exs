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
        # Boot both the example greeter (for the durability demo) and
        # the test services (for the sdk-test-suite conformance run).
        # Both depend on restate_server → restate_protocol, so all four
        # umbrella apps load. The two app modules register independent
        # services on the shared registry; the conformance harness only
        # calls the ones each test class needs (Counter, TestUtilsService).
        applications: [
          restate_example_greeter: :permanent,
          restate_test_services: :permanent
        ],
        include_executables_for: [:unix]
      ]
    ]
  end
end
