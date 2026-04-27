defmodule Restate.TestServices.TestUtilsService do
  @moduledoc """
  Mirror of `dev.restate.sdktesting.contracts.TestUtilsService` — a
  stateless helper service the conformance suite uses across many test
  classes (Sleep, ServiceToServiceCommunication, etc.).

  Only the handlers needed for currently-targeted test classes are
  implemented; the rest are left unregistered so the test runner gets
  a clean 404 (and we know which gap to close next).

  ### Implemented

    * `echo`             — round-trip a string
    * `uppercaseEcho`    — round-trip a string, uppercased
    * `sleepConcurrently` — create N timers and wait on them all
    * `cancelInvocation` — emit a CANCEL signal at the given invocation id

  ### Not yet implemented (omitted from the registration map)

    * `echoHeaders`              — needs request-header plumbing on the Context
    * `rawEcho`                  — needs raw-bytes I/O (handler currently assumes JSON)
    * `countExecutedSideEffects` — needs `ctx.run` (Run command pair, post-v0.1)

  ### sleepConcurrently note

  The Java reference creates all N timers concurrently and `awaitAll`s
  them. Our SDK's `Restate.Context.sleep/2` is sequential — there's no
  promise-style awaitable combinator yet (planned for v0.2). The
  observable difference is journal shape: Java emits N
  SleepCommandMessages then one Suspension; we emit one Sleep +
  Suspension, resume, repeat. Both are protocol-valid; the timing
  assertions in `Sleep.kt` (`elapsed >= duration`) hold for either.
  """

  alias Restate.Context

  def echo(_ctx, input) when is_binary(input), do: input

  def uppercase_echo(_ctx, input) when is_binary(input), do: String.upcase(input)

  def sleep_concurrently(%Context{} = ctx, durations_ms) when is_list(durations_ms) do
    Enum.each(durations_ms, fn ms when is_integer(ms) and ms >= 0 ->
      Context.sleep(ctx, ms)
    end)

    nil
  end

  def cancel_invocation(%Context{} = ctx, invocation_id) when is_binary(invocation_id) do
    Context.cancel_invocation(ctx, invocation_id)
    nil
  end
end
