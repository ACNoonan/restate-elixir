defmodule Restate.PropertyReplayTest do
  @moduledoc """
  Property-based replay-determinism tests over generated handler
  operation sequences. See `Restate.Test.PropertyReplay` for the
  GenericHandler that interprets ops, and
  `Restate.Test.CrashInjection.assert_replay_determinism/3` for the
  per-handler harness this property layer drives.

  Properties tested:

    1. Any generated op sequence is replay-deterministic — every
       prefix of the baseline journal replays to the same terminal
       outcome (either suspended or :value with the same payload),
       and `ctx.run` results journal exactly once.

    2. Empty sequences are valid — a no-op handler is the simplest
       case and must terminate cleanly.

  Generator scope is intentionally tight (≤ 6 ops, three keys, small
  integer values) so tests run in seconds and shrink to readable
  counter-examples. Bumping `max_runs` or `max_length` is the right
  knob if a future regression goes unnoticed.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Restate.Test.CrashInjection
  alias Restate.Test.PropertyReplay.GenericHandler

  @max_ops 6
  @max_runs 100

  property "GenericHandler is replay-deterministic for any op sequence" do
    check all ops <- ops_gen(), max_runs: @max_runs do
      CrashInjection.assert_replay_determinism({GenericHandler, :run, 2}, ops)
    end
  end

  property "stateful sequences replay through the same final state" do
    # Subset focused on state ops — exercise the eager-state path
    # without sleep/run noise. Catches regressions where state
    # writes / reads stop being journal-ordered correctly.
    check all ops <- list_of(state_op_gen(), max_length: @max_ops), max_runs: @max_runs do
      CrashInjection.assert_replay_determinism({GenericHandler, :run, 2}, ops)
    end
  end

  property "ctx.run sequences journal exactly once across replays" do
    # Subset focused on ctx.run — drives the
    # ProposeRunCompletion / RunCompletionNotification dance.
    # `assert_replay_determinism`'s :with_run_completions branch
    # (synthesised completions from the baseline) checks that the
    # SDK skips re-executing the lambda when the completion is in
    # the journal.
    check all ops <- list_of(run_op_gen(), max_length: @max_ops), max_runs: @max_runs do
      CrashInjection.assert_replay_determinism({GenericHandler, :run, 2}, ops)
    end
  end

  test "empty op sequence terminates cleanly" do
    CrashInjection.assert_replay_determinism({GenericHandler, :run, 2}, [])
  end

  # --- Generators ----------------------------------------------------

  defp ops_gen do
    list_of(op_gen(), max_length: @max_ops)
  end

  defp op_gen do
    one_of([
      state_op_gen(),
      tuple_op_gen("get_state", &key_gen/0),
      tuple_op_gen("clear_state", &key_gen/0),
      sleep_op_gen(),
      run_op_gen()
    ])
  end

  defp state_op_gen do
    gen all key <- key_gen(), value <- value_gen() do
      ["set_state", key, value]
    end
  end

  defp run_op_gen do
    gen all value <- value_gen() do
      ["run", value]
    end
  end

  defp sleep_op_gen do
    gen all ms <- integer(1..50) do
      ["sleep", ms]
    end
  end

  defp tuple_op_gen(op_name, key_fun) do
    gen all key <- key_fun.() do
      [op_name, key]
    end
  end

  # Three keys is enough to exercise overwrite + clear-then-read +
  # multi-key interleaving. Wider key spaces just add generator
  # bloat without exercising new SDK code paths.
  defp key_gen do
    one_of([constant("k1"), constant("k2"), constant("k3")])
  end

  defp value_gen do
    integer(0..1000)
  end
end
