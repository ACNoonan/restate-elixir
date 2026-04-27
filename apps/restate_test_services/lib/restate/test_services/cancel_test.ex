defmodule Restate.TestServices.CancelTest do
  @moduledoc """
  Mirror of `dev.restate.sdktesting.contracts.CancelTest` and
  `restatedev/sdk-java`'s `CancelTestImpl.kt`. Exercises cancel
  propagation through three blocking-op shapes:

      BlockingOperation = CALL | SLEEP | AWAKEABLE

  ## Call shape (matches the Java reference)

      Runner.startTest(op):
        try BlockingService.block(op)
        rescue Restate.TerminalError(code: 409) → set state(:canceled, true)
        rescue any other → reraise

      Runner.verifyTest():
        state(:canceled) || false

      BlockingService.block(op):
        awakeable = ctx.awakeable()
        ctx.send_async(AwakeableHolder.hold, awakeable.id)
        ctx.await_awakeable(awakeable)        # always — this is the
                                              # synchronization point
                                              # the test polls on
        case op of
          CALL      → BlockingService.block(op)         # recurse
          SLEEP     → ctx.sleep(1024 days)              # never wakes
          AWAKEABLE → ctx.await_awakeable(<new, uncompletable>)

  After the test calls `unlock("cancel")` to resolve the first
  awakeable, the BlockingService is parked in something that can
  *only* be unblocked by a cancel. That's the actual cancellation
  test. The Runner's `try/catch` is what makes `verifyTest` return
  true — without it the cancel surfaces as a terminal failure and
  the runner has no chance to record state.
  """

  defmodule Runner do
    alias Restate.Context

    @canceled_state "canceled"

    def start_test(%Context{} = ctx, operation) when is_binary(operation) do
      key = Context.key(ctx)

      try do
        Context.call(ctx, "CancelTestBlockingService", "block", operation, key: key)
      rescue
        e in Restate.TerminalError ->
          if e.code == 409 do
            Context.set_state(ctx, @canceled_state, true)
            nil
          else
            reraise e, __STACKTRACE__
          end
      end
    end

    def verify_test(%Context{} = ctx, _input) do
      Context.get_state(ctx, @canceled_state) || false
    end
  end

  defmodule BlockingService do
    alias Restate.Context

    # 1024 days, expressed in milliseconds. Matches the Java reference
    # — the value just needs to be effectively-never within the test's
    # 30-second window.
    @never_ms 1024 * 24 * 60 * 60 * 1000

    def block(%Context{} = ctx, operation) when is_binary(operation) do
      key = Context.key(ctx)

      {awakeable_id, handle} = Context.awakeable(ctx)
      Context.send_async(ctx, "AwakeableHolder", "hold", awakeable_id, key: key)

      # Resolved by the test calling AwakeableHolder.unlock("cancel"),
      # which is what hands control to the operation-specific block.
      _ = Context.await_awakeable(ctx, handle)

      case operation do
        "CALL" ->
          Context.call(ctx, "CancelTestBlockingService", "block", operation, key: key)

        "SLEEP" ->
          Context.sleep(ctx, @never_ms)

        "AWAKEABLE" ->
          {_unused_id, uncompletable} = Context.awakeable(ctx)
          Context.await_awakeable(ctx, uncompletable)

        _ ->
          raise Restate.TerminalError,
            message: "unknown BlockingOperation: #{operation}",
            code: 400
      end

      nil
    end

    def is_unlocked(%Context{} = _ctx, _input), do: nil
  end
end
