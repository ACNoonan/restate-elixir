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
    * `callTerminallyFailingCall(input)` — calls a fresh Failing
      instance's `terminallyFailingCall`. The inner terminal failure
      propagates up via `ctx.call` raising. Tests cross-handler
      terminal-error propagation.
    * `failingCallWithEventualSuccess()` — fails with a non-terminal
      exception three times in a row, succeeds on the fourth attempt.
      Tests that ordinary `raise` produces an `ErrorMessage`, which
      the runtime treats as retryable.

  ### Not yet implemented

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
end
