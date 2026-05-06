defmodule Restate.Test.CrashInjectionTest do
  use ExUnit.Case, async: true

  alias Restate.Test.CrashInjection

  defmodule Handlers do
    @moduledoc false
    alias Restate.Context

    def pure(_ctx, _input), do: 42

    def stateful(ctx, _input) do
      Context.set_state(ctx, "k", "v")
      "set"
    end

    def sleeps(ctx, _input) do
      Context.sleep(ctx, 100)
      "slept"
    end

    def multi_step(ctx, _input) do
      Context.set_state(ctx, "step", "1")
      Context.sleep(ctx, 100)
      Context.set_state(ctx, "step", "2")
      Context.sleep(ctx, 100)
      "done"
    end

    def reads_input(_ctx, input), do: %{"echo" => input}

    def raises_terminal(_ctx, _input) do
      raise %Restate.TerminalError{code: 422, message: "nope"}
    end

    # Deliberately non-deterministic: `:erlang.unique_integer/1`
    # returns a globally distinct value per call, so two runs of this
    # handler will never agree. The harness should catch this on the
    # full-prefix (k=0) baseline-vs-replay comparison.
    def non_deterministic(_ctx, _input) do
      %{"id" => :erlang.unique_integer([:positive])}
    end

    # ctx.run wrapping a side-effecting function. The counter key is
    # passed via input so each test gets an isolated counter and
    # `async: true` is safe.
    def runs_once_with_counter(ctx, %{"counter_key" => key}) when is_binary(key) do
      Restate.Context.run(ctx, fn ->
        n = :persistent_term.get(key, 0)
        :persistent_term.put(key, n + 1)
        "ai-result"
      end)
    end

    # ctx.run with a non-deterministic function. In production this is
    # fine because the journaled completion is replayed; the harness's
    # Branch B (synthesised completions) MUST agree with baseline.
    def non_deterministic_run(ctx, _input) do
      Restate.Context.run(ctx, fn ->
        :erlang.unique_integer([:positive])
      end)
    end
  end

  describe "deterministic handlers pass" do
    test "pure handler — empty journal, no commands" do
      assert :ok = CrashInjection.assert_replay_determinism({Handlers, :pure, 2})
    end

    test "stateful handler — single SetState command" do
      assert :ok = CrashInjection.assert_replay_determinism({Handlers, :stateful, 2})
    end

    test "sleeping handler — Sleep command + suspension" do
      assert :ok = CrashInjection.assert_replay_determinism({Handlers, :sleeps, 2})
    end

    test "multi-step handler — three SetState + two Sleep across replay boundaries" do
      assert :ok = CrashInjection.assert_replay_determinism({Handlers, :multi_step, 2})
    end

    test "input is threaded through replay runs" do
      assert :ok =
               CrashInjection.assert_replay_determinism(
                 {Handlers, :reads_input, 2},
                 %{"name" => "world"}
               )
    end

    test "terminal error is also deterministic" do
      assert :ok =
               CrashInjection.assert_replay_determinism({Handlers, :raises_terminal, 2})
    end
  end

  describe "non-deterministic handlers are caught" do
    test "unique-integer handler raises with diagnostic" do
      assert_raise RuntimeError, ~r/Replay determinism violated/, fn ->
        CrashInjection.assert_replay_determinism({Handlers, :non_deterministic, 2})
      end
    end
  end

  describe "ctx.run determinism" do
    test "harness drives baseline through ctx.run suspensions to terminal" do
      key = unique_counter_key()

      try do
        assert :ok =
                 CrashInjection.assert_replay_determinism(
                   {Handlers, :runs_once_with_counter, 2},
                   %{"counter_key" => key}
                 )
      after
        :persistent_term.erase(key)
      end
    end

    test "Branch B (synthesised completions) skips the user function" do
      key = unique_counter_key()

      try do
        :ok =
          CrashInjection.assert_replay_determinism(
            {Handlers, :runs_once_with_counter, 2},
            %{"counter_key" => key}
          )

        # Trace for a one-`ctx.run` handler:
        #   * Baseline iter 1: function runs (counter=1), proposes,
        #     suspends. Loop synthesises completion.
        #   * Baseline iter 2: function NOT run, returns recorded
        #     value, handler terminates.
        #   * Prefix k=0, Branch A: handler in :processing, function
        #     runs (counter=2), proposes, suspends.
        #   * Prefix k=1, Branch A: replay with no completion, falls
        #     to :execute, function runs (counter=3).
        #   * Prefix k=1, Branch B: replay with synthesised completion,
        #     function NOT run.
        #
        # Total: 3. If Branch B were also re-running the function this
        # would be 4, which would mean exactly-once was broken.
        assert :persistent_term.get(key, 0) == 3
      after
        :persistent_term.erase(key)
      end
    end

    test "non-deterministic ctx.run trips Branch A but Branch B passes against baseline" do
      # Baseline drives the handler to a terminal via synthesised
      # completion (function called once). Branch B on the full
      # prefix synthesises the same completion, returns the same
      # value, terminates with same value as baseline → passes.
      # Branch A on the full prefix re-executes the function,
      # producing a *different* unique integer → outcome is
      # :suspended (re-execute requires another round-trip), which
      # the harness accepts. So this handler is allowed by the
      # current rule set even though its function is
      # non-deterministic — production-correct because Restate
      # always journals the completion before re-invoking.
      assert :ok = CrashInjection.assert_replay_determinism({Handlers, :non_deterministic_run, 2})
    end
  end

  defp unique_counter_key do
    "crash-injection-counter-#{:erlang.unique_integer([:positive])}"
  end
end
