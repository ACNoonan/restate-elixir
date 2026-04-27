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

  ## Cancellation propagation

  Restate's cancel-signal mechanism uses the reserved signal-id 1
  (per `BuiltInSignal.CANCEL` in protocol.proto:670). When an
  invocation is killed via the admin API, the runtime delivers a
  `SignalNotificationMessage{signal_id: 1}` to every awaiting
  invocation in the call tree. The SDK detects it during journal
  partitioning and raises `Restate.TerminalError{code: 409,
  message: "cancelled"}` from the next suspending Context op, which
  propagates up the user handler and out as
  `OutputCommandMessage{failure}`. The runtime cascades the kill
  down through any in-flight callees (here: runner → singleton).

  After the kill cascades, the singleton's VirtualObject key is
  released, so `isUnlocked` (a fresh invocation on the same key)
  acquires the lock and returns `true` — that's the assertion the
  conformance test makes.
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
