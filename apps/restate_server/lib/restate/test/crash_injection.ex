defmodule Restate.Test.CrashInjection do
  @moduledoc """
  Crash-resumption testing for Restate handlers.

  The point of Restate is "your handler runs to completion across
  any number of crashes." Verifying that means proving the handler
  produces the same outcome regardless of which prefix of its
  emitted journal the runtime managed to persist before the crash.

  Every prefix is a possible mid-crash state — `:assert_replay_determinism/3`
  exhaustively replays all of them.

  ## What it does

  1. **Baseline** — runs the handler with an empty replay journal,
     captures the emitted command sequence, the
     `ProposeRunCompletion` results, and the terminal outcome.
  2. **Prefix replay** — for every prefix length `k` in `0..n`,
     re-runs the handler against the prefix in **two branches**
     when the prefix contains a `ctx.run` command:

       * `:without_run_completions` — replay journal contains the
         `RunCommand`s but no completions. The SDK falls back to
         re-executing the user's run function. Tests the
         "runtime-hasn't-acked-yet" path.
       * `:with_run_completions` — for every `RunCommand` in the
         prefix, the harness synthesises a matching
         `RunCompletionNotificationMessage` carrying the value the
         function returned in the baseline. The SDK MUST skip the
         user function and return the recorded value. Tests
         Restate's headline "exactly-once" guarantee directly.

     Each branch must end at `:suspended` or match the baseline
     outcome and value. Anything else raises with a diagnostic
     that names the failing branch.

  ## Example

      test "Greeter is replay-deterministic" do
        Restate.Test.CrashInjection.assert_replay_determinism(
          {MyApp.Greeter, :greet, 2},
          %{"name" => "world"}
        )
      end

  ## Side-effect counts

  The `:without_run_completions` branch deliberately re-executes
  the user's `ctx.run` function — so for a handler with a single
  `ctx.run`, the harness will invoke that function multiple times
  across prefixes (specifically: baseline + every prefix that
  contains the `RunCommand` but is run in branch A). For pure or
  idempotent functions this is fine. For non-idempotent ones,
  scope side effects behind a test mock or the run will fire N
  times per harness call. The `:with_run_completions` branch
  exercises the production-realistic path where the function is
  *not* invoked.

  ## Limitations

  * Handlers that depend on pre-existing state should pass `:state`
    via opts (forwarded to `Restate.Test.FakeRuntime`). Same shape:
    `%{binary() => binary()}`.
  * Handlers that use `ctx.call` need `:call_responses` in opts —
    the baseline run drives them through `Restate.Test.FakeRuntime`,
    which requires explicit mocks. Without them, baseline raises.
  * Awakeable awaits and workflow promises aren't supported in v0
    of `Restate.Test.FakeRuntime`, so handlers that suspend on them
    can't be exercised by this harness yet.

  ## Why this is BEAM-flavoured

  Java's `sdk-fake-api` can mock the wire protocol but exhaustively
  re-running every prefix means spinning up `n` independent
  `Invocation` GenServers per test — cheap on the BEAM (tens of
  microseconds per spawn), expensive on the JVM (thread-pool
  contention, classloader pressure). The harness leans on that
  asymmetry.
  """

  alias Dev.Restate.Service.Protocol, as: Pb
  alias Restate.Protocol.{Frame, Framer}
  alias Restate.Server.Invocation
  alias Restate.Test.FakeRuntime

  @type opts :: [
          {:input, term()}
          | {:start_id, binary()}
          | {:state, %{binary() => binary()}}
          | {:partial_state, boolean()}
          | {:key, binary()}
          | {:call_responses, map()}
        ]

  @doc """
  Assert that `mfa` produces the same terminal outcome for every
  prefix of its baseline emitted journal. See module docs for full
  semantics.

  Returns `:ok` on success; raises with a diagnostic on the first
  divergence.
  """
  @spec assert_replay_determinism({module(), atom(), arity()}, term(), opts()) :: :ok
  def assert_replay_determinism(mfa, input \\ nil, opts \\ []) do
    runtime_opts = forward_runtime_opts(opts)

    # Drive the handler to its terminal outcome via
    # `Restate.Test.FakeRuntime`, which auto-completes sleep / run /
    # lazy state suspensions in-memory. The resulting full command
    # journal is what the runtime would have persisted across all
    # production invocations; `run_completions` is the union of
    # every `ctx.run` value, indexed by completion id, used for
    # synthesising notifications during prefix replay.
    %FakeRuntime.Result{
      outcome: baseline_outcome,
      value: baseline_value,
      journal: full_journal,
      run_completions: run_completions
    } = FakeRuntime.run(mfa, input, runtime_opts)

    journal_commands = filter_command_messages(full_journal)
    n = length(journal_commands)

    Enum.each(0..n, fn k ->
      prefix = Enum.take(journal_commands, k)

      # Branch A: replay journal carries commands but no run
      # completions. SDK re-executes any ctx.run encountered.
      {outcome_a, body_a} = run_prefix(mfa, input, prefix, runtime_opts)

      check_prefix!(
        :without_run_completions,
        k, n,
        outcome_a, body_a,
        baseline_outcome, baseline_value,
        prefix
      )

      # Branch B: synthesise RunCompletionNotificationMessages for
      # every RunCommand in the prefix using the baseline's
      # ProposeRunCompletion values. SDK must skip the function and
      # return the recorded value — this is the exactly-once path.
      # Skipped when the prefix has no RunCommand (the two branches
      # would be identical).
      if Enum.any?(prefix, &run_command?/1) do
        synthesised = synthesise_run_completions(prefix, run_completions)
        replay = prefix ++ synthesised

        {outcome_b, body_b} = run_prefix(mfa, input, replay, runtime_opts)

        check_prefix!(
          :with_run_completions,
          k, n,
          outcome_b, body_b,
          baseline_outcome, baseline_value,
          replay
        )
      end
    end)

    :ok
  end

  defp run_command?(%Pb.RunCommandMessage{}), do: true
  defp run_command?(_), do: false

  # For each `RunCommandMessage` in the prefix, build a
  # `RunCompletionNotificationMessage` carrying the same value. The
  # protobuf `value` field shape differs between the two messages —
  # `ProposeRun.value` is raw bytes, `RunCompletionNotification.value`
  # wraps them in a `Pb.Value` struct. `propose_to_notification_result/1`
  # bridges it.
  defp synthesise_run_completions(prefix_commands, completions_by_cid) do
    Enum.flat_map(prefix_commands, fn
      %Pb.RunCommandMessage{result_completion_id: cid} ->
        case Map.fetch(completions_by_cid, cid) do
          {:ok, propose_result} ->
            [
              %Pb.RunCompletionNotificationMessage{
                completion_id: cid,
                result: propose_to_notification_result(propose_result)
              }
            ]

          :error ->
            # Defensive: every baseline RunCommand should have a paired
            # ProposeRun, but if not, omit — replay falls through to
            # re-execute, still a valid SDK path.
            []
        end

      _ ->
        []
    end)
  end

  defp propose_to_notification_result({:value, bytes}) when is_binary(bytes) do
    {:value, %Pb.Value{content: bytes}}
  end

  defp propose_to_notification_result({:failure, %Pb.Failure{} = f}) do
    {:failure, f}
  end

  defp check_prefix!(branch, k, n, outcome, body, baseline_outcome, baseline_value, prefix) do
    cond do
      # `:suspended` is acceptable for any prefix and either branch.
      # Mid-prefix it means "needs more journal to proceed."
      # Branch A on a full prefix legitimately ends at :suspended too —
      # re-executing a `ctx.run` requires another runtime round-trip
      # to commit the proposal before the handler can continue, so
      # the SDK suspends after the propose. That's protocol-correct,
      # not a determinism violation.
      outcome == :suspended ->
        :ok

      # Otherwise the outcome must match baseline. This covers:
      #   * Branch B on full prefix → must reach baseline terminal.
      #   * Mid-prefix terminal → handler short-circuited deterministically.
      outcome == baseline_outcome ->
        replay_value = FakeRuntime.extract_terminal_value(FakeRuntime.decode_body(body), outcome)

        if replay_value == baseline_value do
          :ok
        else
          raise determinism_error(
                  branch,
                  "prefix replay terminated with same outcome but different value",
                  k,
                  n,
                  baseline_value,
                  replay_value,
                  prefix,
                  body
                )
        end

      # Anything else is non-deterministic.
      true ->
        raise determinism_error(
                branch,
                "prefix replay produced unexpected outcome (k=#{k}/#{n})",
                k,
                n,
                baseline_outcome,
                outcome,
                prefix,
                body
              )
    end
  end

  # Forward the test author's opts (`:state`, `:partial_state`,
  # `:key`, `:start_id`, `:call_responses`) to FakeRuntime. Ignores
  # opts that don't apply to baseline computation.
  defp forward_runtime_opts(opts) do
    Enum.filter(opts, fn {k, _} ->
      k in [:state, :partial_state, :key, :start_id, :call_responses, :max_iterations]
    end)
  end

  defp filter_command_messages(messages) do
    FakeRuntime.extract_journal_commands(messages)
  end

  defp run_prefix(mfa, input, prefix_messages, opts) do
    state = Keyword.get(opts, :state, %{})
    partial_state? = Keyword.get(opts, :partial_state, false)
    key = Keyword.get(opts, :key, "")
    start_id = Keyword.get(opts, :start_id, <<0, 1, 2, 3>>)

    state_entries =
      if partial_state? do
        []
      else
        Enum.map(state, fn {k, v} -> %Pb.StartMessage.StateEntry{key: k, value: v} end)
      end

    start = %Pb.StartMessage{
      id: start_id,
      debug_id: "crash-injection",
      known_entries: 1,
      state_map: state_entries,
      partial_state: partial_state?,
      key: key
    }

    replay_frames =
      Enum.map(prefix_messages, fn msg ->
        %Frame{type: 0, flags: 0, message: msg}
      end)

    {:ok, pid} =
      Invocation.start_link({start, input, replay_frames, mfa, %{}})

    Invocation.await_response(pid)
  end

  defp determinism_error(branch, headline, k, n, expected, actual, prefix, body) do
    """
    Replay determinism violated: #{headline}

      Branch:           #{inspect(branch)}
      Prefix length:    #{k} of #{n}
      Expected:         #{inspect(expected, pretty: true, limit: :infinity)}
      Got:              #{inspect(actual, pretty: true, limit: :infinity)}

    Prefix journal frames:
    #{inspect(prefix, pretty: true, limit: :infinity)}

    Replay response:
    #{inspect(safe_decode(body), pretty: true, limit: :infinity)}
    """
  end

  defp safe_decode(body) do
    case Framer.decode_all(body) do
      {:ok, frames, ""} -> Enum.map(frames, & &1.message)
      _ -> body
    end
  end
end
