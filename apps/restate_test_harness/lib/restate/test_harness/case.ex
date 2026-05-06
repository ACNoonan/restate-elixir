defmodule Restate.TestHarness.Case do
  @moduledoc """
  ExUnit case template that boots a `restate-server` container per test
  and exposes it as `context.restate` (a `Restate.TestHarness.Instance`).

  ## Usage

      defmodule MyHandler.IntegrationTest do
        use Restate.TestHarness.Case

        @moduletag :integration

        test "greet returns a personalized message", %{restate: instance} do
          :ok = Restate.TestHarness.register_deployment(instance,
                  uri: "http://host.docker.internal:9080",
                  use_http_11: true)

          {:ok, %{status: 200, body: body}} =
            Restate.TestHarness.invoke(instance, "Greeter/world/greet",
              %{"name" => "world"})

          assert body == "hello, world"
        end
      end

  ## Options

  Pass options to the harness via `:restate_harness` tags:

      @tag restate_harness: [image: "docker.restate.dev/restatedev/restate:1.5.0"]
      test "older server still works", %{restate: instance} do
        ...
      end

  All `Restate.TestHarness.start_link/1` options are accepted.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Restate.TestHarness.Case
    end
  end

  setup tags do
    opts = Map.get(tags, :restate_harness, [])
    {:ok, harness} = start_supervised({Restate.TestHarness.Server, opts})
    instance = Restate.TestHarness.info(harness)
    {:ok, restate: instance, restate_harness: harness}
  end
end
