defmodule Restate.TestServices.Failing do
  @moduledoc """
  Mirror of `dev.restate.sdktesting.contracts.Failing` — exercises
  `Restate.TerminalError` propagation and the runtime's retry behavior
  on non-terminal failures.

  ### Implemented

    * `terminallyFailingCall(input)` — raise `Restate.TerminalError`
      with the supplied message and optional metadata.
    * `callTerminallyFailingCall(input)` — calls a fresh Failing
      instance's `terminallyFailingCall`. The inner terminal failure
      propagates up via `ctx.call` raising.
    * `terminallyFailingSideEffect(input)` — wraps the terminal
      raise inside a `ctx.run`. The Run-command's failure
      notification re-raises on replay, propagating to the outer
      handler's response.
    * `failingCallWithEventualSuccess()` — fails with a non-terminal
      exception three times in a row, succeeds on the fourth attempt.
    * `sideEffectSucceedsAfterGivenAttempts(N)` — `ctx.run` with
      infinite retry policy. Function increments a class-level
      counter; throws until count >= 4, then returns the count.
      Used by `RunRetry.withSuccess`.
    * `sideEffectFailsAfterGivenAttempts(N)` — `ctx.run` with
      `max_attempts: N`. Function always throws. After exhaustion
      the SDK proposes a terminal failure; the handler catches
      and returns the (post-retry) counter. Used by
      `RunRetry.executedOnlyOnce` / `RunRetry.withExhaustedAttempts`.

  ## Why ETS for the counters

  Java keeps these as `AtomicInteger` instance fields on a singleton
  service impl — they persist across invocations within the JVM. Our
  equivalent is a named ETS table: handler processes come and go
  per-invocation, but the table outlives them and supports atomic
  increments via `:ets.update_counter/3`. Same observable behaviour.
  """

  @counter_table :restate_test_services_failing_counters

  @doc false
  def init_table do
    case :ets.whereis(@counter_table) do
      :undefined ->
        :ets.new(@counter_table, [:set, :public, :named_table])

      _ ->
        @counter_table
    end

    :ets.insert(@counter_table, {:eventual_success, 0})
    :ets.insert(@counter_table, {:eventual_success_side_effect, 0})
    :ets.insert(@counter_table, {:eventual_failure_side_effect, 0})
    :ok
  end

  def terminally_failing_call(_ctx, %{"errorMessage" => message} = input) do
    metadata = Map.get(input, "metadata") || %{}
    raise Restate.TerminalError, message: message, metadata: metadata
  end

  def terminally_failing_side_effect(
        %Restate.Context{} = ctx,
        %{"errorMessage" => message} = input
      ) do
    metadata = Map.get(input, "metadata") || %{}

    Restate.Context.run(ctx, fn ->
      raise Restate.TerminalError, message: message, metadata: metadata
    end)

    # Unreachable: ctx.run re-raises the TerminalError.
    raise "should be unreachable"
  end

  def call_terminally_failing_call(%Restate.Context{} = ctx, %{"errorMessage" => _} = input) do
    # Java reference: spawn a fresh Failing key, call its
    # terminallyFailingCall, propagate the terminal failure up.
    key = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)

    Restate.Context.call(ctx, "Failing", "terminallyFailingCall", input, key: key)

    # Unreachable: the call raises Restate.TerminalError, which the
    # SDK then maps to OutputCommandMessage{failure} on this
    # invocation's response. The runtime propagates it back to the
    # ingress client as the failure of *this* call.
    raise "should be unreachable"
  end

  def failing_call_with_eventual_success(_ctx, _input) do
    attempt = :ets.update_counter(@counter_table, :eventual_success, 1)

    if attempt >= 4 do
      :ets.insert(@counter_table, {:eventual_success, 0})
      attempt
    else
      raise "Failed at attempt: #{attempt}"
    end
  end

  def side_effect_succeeds_after_given_attempts(%Restate.Context{} = ctx, minimum_attempts)
      when is_integer(minimum_attempts) do
    Restate.Context.run(
      ctx,
      fn ->
        attempt = :ets.update_counter(@counter_table, :eventual_success_side_effect, 1)

        if attempt >= 4 do
          :ets.insert(@counter_table, {:eventual_success_side_effect, 0})
          attempt
        else
          raise "Failed at attempt: #{attempt}"
        end
      end,
      initial_interval_ms: 10,
      factor: 1.0
    )
  end

  def side_effect_fails_after_given_attempts(%Restate.Context{} = ctx, max_retry_count)
      when is_integer(max_retry_count) do
    try do
      Restate.Context.run(
        ctx,
        fn ->
          attempt = :ets.update_counter(@counter_table, :eventual_failure_side_effect, 1)
          raise "Failed at attempt: #{attempt}"
        end,
        max_attempts: max_retry_count,
        initial_interval_ms: 10,
        factor: 1.0
      )

      # Unreachable: the run is always failing.
      raise Restate.TerminalError,
        message: "expected the side-effect to fail",
        code: 500
    rescue
      _ in Restate.TerminalError ->
        # The retry budget was exhausted. Read the post-retry counter
        # and return it — the test asserts response >= max_retry_count.
        [{_, count}] = :ets.lookup(@counter_table, :eventual_failure_side_effect)
        count
    end
  end
end
