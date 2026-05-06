defmodule Restate.TestHarnessV2Test do
  @moduledoc """
  Fault-injection tests — exercise the v2 helpers against the example
  Greeter service. The headline scenario is Demo 1 automated: handler
  crashes during a suspended sleep, recovers, journal replays through
  the completed sleep, invocation returns the original payload.
  """

  use ExUnit.Case, async: false

  alias Restate.TestHarness
  alias Restate.TestHarness.Sdk

  @moduletag :integration
  @moduletag timeout: 90_000

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

  test "container pause + unpause — invocation completes after recovery", %{restate: instance} do
    key = "k-pause-" <> Integer.to_string(:erlang.unique_integer([:positive]))

    task =
      Task.async(fn ->
        TestHarness.invoke(instance, "Greeter/#{key}/count", nil, timeout: 30_000)
      end)

    Process.sleep(100)

    :ok = TestHarness.pause(instance)
    Process.sleep(500)
    :ok = TestHarness.unpause(instance)

    {:ok, %{status: 200, body: body}} = Task.await(task, 35_000)
    assert body == "hello 1"
  end

  test "handler crash mid-suspended-sleep — journal replay completes invocation",
       %{restate: instance} do
    key = "k-crash-" <> Integer.to_string(:erlang.unique_integer([:positive]))

    {:ok, invocation_id} =
      TestHarness.send_async(instance, "Greeter/#{key}/long_greet", "world")

    # Give the SDK a moment to receive the POST, journal the
    # set_state + sleep entries, and emit Suspension. After this
    # point the original HTTP request has already returned cleanly;
    # the sleep timer is on Restate's side.
    Process.sleep(1_000)

    # Pod kill, BEAM-style. Drops the Bandit listener and every
    # live Invocation GenServer.
    :ok = Sdk.crash()
    Process.sleep(200)

    # Bring the runtime back. handler app's start/2 re-registers
    # Greeter on the fresh registry. Bandit re-binds the same port
    # so Restate's retry hits the recovered SDK.
    {:ok, _} = Sdk.recover()

    # The sleep is 10s on Restate's side. After it fires, Restate
    # POSTs the full replay journal to the SDK; the handler walks
    # past the journaled sleep, runs the post-sleep set_state, and
    # returns "hello world". Attach blocks until that completes.
    {:ok, %{status: 200, body: body}} =
      TestHarness.attach(instance, invocation_id, timeout: 30_000)

    assert body == "hello world"
  end
end
