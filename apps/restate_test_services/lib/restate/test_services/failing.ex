defmodule Restate.TestServices.Failing do
  @moduledoc """
  Mirror of `dev.restate.sdktesting.contracts.Failing` — exercises
  `Restate.TerminalError` propagation and the runtime's retry behavior
  on non-terminal failures.

  ### Implemented

    * `terminallyFailingCall(input)` — raise `Restate.TerminalError`
      with the supplied message and optional metadata. Tests the
      OutputCommandMessage{failure} mapping end-to-end through
      Restate's ingress.
    * `failingCallWithEventualSuccess()` — fails with a non-terminal
      exception three times in a row, succeeds on the fourth attempt.
      Tests that ordinary `raise` produces an `ErrorMessage`, which
      the runtime treats as retryable.

  ### Not yet implemented

    * `callTerminallyFailingCall`     — needs `ctx.call`  (post-v0.1)
    * `terminallyFailingSideEffect`   — needs `ctx.run`   (post-v0.1)
    * `sideEffectSucceedsAfterGivenAttempts` — needs `ctx.run`
    * `sideEffectFailsAfterGivenAttempts`    — needs `ctx.run`
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
    :ok
  end

  def terminally_failing_call(_ctx, %{"errorMessage" => message} = input) do
    metadata = Map.get(input, "metadata") || %{}
    raise Restate.TerminalError, message: message, metadata: metadata
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
end
