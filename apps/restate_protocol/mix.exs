defmodule Restate.Protocol.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/ACNoonan/restate-elixir"

  def project do
    [
      app: :restate_protocol,
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
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:protobuf, "~> 0.16.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Restate service-protocol V5 wire-format definitions for Elixir — generated protobuf modules + Frame/Framer for the 8-byte message header. Used internally by the `restate` SDK; depend on this directly only if you're building Restate tooling that operates below the Context API."
  end

  defp package do
    [
      licenses: ["MIT"],
      maintainers: ["Adam Noonan <adam@samachi.com>"],
      links: %{
        "GitHub" => @source_url,
        "Restate" => "https://restate.dev"
      },
      files: ~w(lib proto mix.exs README.md ../../LICENSE ../../CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md": [title: "README"], "../../CHANGELOG.md": [title: "Changelog"]],
      source_ref: "v#{@version}"
    ]
  end
end
