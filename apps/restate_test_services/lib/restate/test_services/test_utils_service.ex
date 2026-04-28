defmodule Restate.TestServices.TestUtilsService do
  @moduledoc """
  Mirror of `dev.restate.sdktesting.contracts.TestUtilsService` — a
  stateless helper service the conformance suite uses across many test
  classes (Sleep, ServiceToServiceCommunication, etc.).

  Only the handlers needed for currently-targeted test classes are
  implemented; the rest are left unregistered so the test runner gets
  a clean 404 (and we know which gap to close next).

  ### Implemented

    * `echo`                     — round-trip a string
    * `uppercaseEcho`            — round-trip a string, uppercased
    * `sleepConcurrently`        — create N timers and wait on them all
    * `cancelInvocation`         — emit a CANCEL signal at the given invocation id
    * `countExecutedSideEffects` — call `ctx.run` N times; each run
      increments an invocation-local `:counters` ref. The conformance
      `RunFlush` test asserts the final response is 0 — the SDK
      suspends after each ProposeRunCompletion, so on the final
      replay none of the runs re-execute and the counter stays at 0.

  ### Not yet implemented (omitted from the registration map)

    * `echoHeaders` — needs request-header plumbing on the Context
    * `rawEcho`    — needs raw-bytes I/O (handler currently assumes JSON)

  ### sleepConcurrently note

  Mirrors the Java reference: emit N `SleepCommand`s up front via
  `Context.timer/2`, then `Restate.Awaitable.all/2` over the handles.
  Single suspension whose `waiting_completions` lists every timer id;
  the runtime fires them in parallel and re-invokes us once with all
  the completion notifications in the journal.
  """

  alias Restate.Context

  def echo(_ctx, input) when is_binary(input), do: input

  def uppercase_echo(_ctx, input) when is_binary(input), do: String.upcase(input)

  def sleep_concurrently(%Context{} = ctx, durations_ms) when is_list(durations_ms) do
    handles =
      Enum.map(durations_ms, fn ms when is_integer(ms) and ms >= 0 ->
        Context.timer(ctx, ms)
      end)

    Restate.Awaitable.all(ctx, handles)
    nil
  end

  def cancel_invocation(%Context{} = ctx, invocation_id) when is_binary(invocation_id) do
    Context.cancel_invocation(ctx, invocation_id)
    nil
  end

  def count_executed_side_effects(%Context{} = ctx, increments) when is_integer(increments) do
    counter = :counters.new(1, [])

    Enum.each(1..increments//1, fn _ ->
      Context.run(ctx, fn -> :counters.add(counter, 1, 1) end)
    end)

    :counters.get(counter, 1)
  end
end
