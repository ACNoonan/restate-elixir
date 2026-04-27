defmodule Restate.TestServices.KillTest do
  @moduledoc """
  Mirror of `dev.restate.sdktesting.contracts.KillTest`. Used by the
  `KillInvocation` conformance test to exercise cancellation
  propagation across a synchronous call tree.

  ## Call shape (per the Java reference)

      Test → KillTestRunner.startCallTree(key)
        Runner.startCallTree(key)
          → ctx.call(KillTestSingleton[key].recursiveCall)
              ↓
              Singleton.recursiveCall:
                awakeable = ctx.awakeable()
                ctx.send_async(AwakeableHolder[key].hold(awakeable.id))
                ctx.await_awakeable(awakeable)
                # then recursive call back to itself

  The test then issues `InvocationApi.killInvocation(runner_id)`,
  which Restate is supposed to propagate down: cancel the runner →
  cancel its outstanding ctx.call to the singleton → cancel the
  singleton's outstanding `await_awakeable`.

  ## Cancellation gap (v0.2)

  This test does not yet pass. Restate's cancel-signal mechanism
  uses the reserved signal-id 1 (per
  `AsyncResultsState.java:31`) — when an invocation is killed the
  runtime delivers a `SignalNotificationMessage{signal_id: 1}` to
  every awaiting invocation in the tree. Our SDK does not yet handle
  the cancel signal: receiving signal_id 1 should raise a
  cancellation exception inside `await_awakeable` / `call` /
  `await_call_result`, which propagates up to the user handler.

  Scaffolded here so the test runner discovers the services
  (no more 404), and so the cancellation-handling work in v0.2 has
  a clear set of receiving handlers to wire into.
  """

  defmodule Runner do
    alias Restate.Context

    def start_call_tree(%Context{} = ctx, _input) do
      key = Context.key(ctx)
      Context.call(ctx, "KillTestSingleton", "recursiveCall", nil, key: key)
    end
  end

  defmodule Singleton do
    alias Restate.Context

    def recursive_call(%Context{} = ctx, _input) do
      key = Context.key(ctx)

      {awakeable_id, handle} = Context.awakeable(ctx)

      Context.send_async(ctx, "AwakeableHolder", "hold", awakeable_id, key: key)
      _result = Context.await_awakeable(ctx, handle)

      Context.call(ctx, "KillTestSingleton", "recursiveCall", nil, key: key)
    end

    def is_unlocked(%Context{} = _ctx, _input), do: nil
  end
end
