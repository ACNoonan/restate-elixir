defmodule Restate.TestHarnessE2ETest do
  @moduledoc """
  Cross-app end-to-end test: drives the in-tree `Restate.Example.Greeter`
  Virtual Object through the harness against a real `restate-server`
  container. Proves the SDK, the harness, and the wire protocol all
  agree end-to-end.
  """

  use ExUnit.Case, async: false

  alias Restate.TestHarness
  alias Restate.TestHarness.Sdk

  @moduletag :integration
  @moduletag timeout: 120_000

  setup_all do
    {:ok, %{port: sdk_port}} = Sdk.start(handler_app: :restate_example_greeter)

    {:ok, harness} = TestHarness.start_link(health_timeout_ms: 60_000)
    instance = TestHarness.info(harness)

    :ok =
      TestHarness.register_deployment(instance,
        uri: "http://host.docker.internal:#{sdk_port}",
        use_http_11: true
      )

    on_exit(fn ->
      if Process.alive?(harness), do: TestHarness.stop(harness)
    end)

    {:ok, restate: instance, sdk_port: sdk_port}
  end

  test "Greeter/count round-trip — state persists across invocations", %{restate: instance} do
    key = "k-" <> Integer.to_string(:erlang.unique_integer([:positive]))

    {:ok, %{status: 200, body: body1}} =
      TestHarness.invoke(instance, "Greeter/#{key}/count", nil)

    assert body1 == "hello 1"

    {:ok, %{status: 200, body: body2}} =
      TestHarness.invoke(instance, "Greeter/#{key}/count", nil)

    assert body2 == "hello 2"

    {:ok, %{status: 200, body: body3}} =
      TestHarness.invoke(instance, "Greeter/#{key}/count", nil)

    assert body3 == "hello 3"
  end

  test "Greeter/count — distinct keys keep distinct counters", %{restate: instance} do
    key_a = "ka-" <> Integer.to_string(:erlang.unique_integer([:positive]))
    key_b = "kb-" <> Integer.to_string(:erlang.unique_integer([:positive]))

    {:ok, %{body: a1}} = TestHarness.invoke(instance, "Greeter/#{key_a}/count", nil)
    {:ok, %{body: a2}} = TestHarness.invoke(instance, "Greeter/#{key_a}/count", nil)
    {:ok, %{body: b1}} = TestHarness.invoke(instance, "Greeter/#{key_b}/count", nil)

    assert a1 == "hello 1"
    assert a2 == "hello 2"
    assert b1 == "hello 1"
  end

end
