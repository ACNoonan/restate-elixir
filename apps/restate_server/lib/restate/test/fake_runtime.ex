defmodule Restate.Test.FakeRuntime do
  @moduledoc """
  In-memory test runtime for Restate handlers.

  Drives a handler all the way to its terminal outcome by spawning
  the SDK's `Invocation` GenServer, watching what it emits, and
  synthesising the completion notifications a real `restate-server`
  would deliver. Lets you unit-test handlers without a live
  runtime, a docker-compose stack, or an HTTP listener.

  ## Auto-completed suspensions

  | Suspension on            | What this runtime delivers                    |
  | ------------------------ | --------------------------------------------- |
  | `ctx.sleep`              | `SleepCompletionNotification{void}` instantly |
  | `ctx.run`                | `RunCompletionNotification` from the SDK's `ProposeRun` value |
  | lazy `Context.get_state` | served from the initial `:state` opt          |
  | lazy state keys          | served from the initial `:state` opt          |
  | `ctx.send` (blocking)    | synthetic invocation id (`"fake-inv-<cid>"`)  |

  ## Requires explicit setup

  | Suspension on   | How to provide                                    |
  | --------------- | ------------------------------------------------- |
  | `ctx.call`      | `:call_responses` opt — see below                 |
  | awakeable await | not yet supported in v0; raises with explanation  |
  | workflow promise | not yet supported in v0; raises with explanation |

  ## Result struct

  `Restate.Test.FakeRuntime.Result.t/0`:

      %Restate.Test.FakeRuntime.Result{
        outcome: :value | :terminal_failure | :error | :journal_mismatch,
        value: term(),         # decoded JSON, or %Restate.TerminalError{}, or %Pb.ErrorMessage{}
        state: %{binary() => binary()},  # final state after applying the journal's set/clear ops
        journal: [Pb message],  # full transcript across all suspend-resume cycles
        run_completions: %{integer() => oneof_result},  # ctx.run results indexed by completion id
        iterations: pos_integer()
      }

  ## Example

      result = Restate.Test.FakeRuntime.run(
        {MyApp.Greeter, :greet, 2},
        %{"name" => "world"},
        state: %{"counter" => "1"}
      )

      assert result.outcome == :value
      assert result.value == "hello 2"
      assert result.state["counter"] == "2"

  ## Why this exists

  The official Java SDK ships `sdk-fake-api` for offline handler
  testing. This is the BEAM equivalent. `Restate.Test.CrashInjection`
  uses it under the hood to drive baseline runs for any handler shape,
  not just `ctx.run`-only ones.
  """

  alias Dev.Restate.Service.Protocol, as: Pb
  alias Restate.Protocol.{Frame, Framer}
  alias Restate.Server.Invocation

  defmodule Result do
    @moduledoc "See `Restate.Test.FakeRuntime`."
    @enforce_keys [:outcome, :value, :state, :journal, :run_completions, :iterations]
    defstruct [:outcome, :value, :state, :journal, :run_completions, :iterations]

    @type outcome ::
            :value | :terminal_failure | :error | :journal_mismatch

    @type t :: %__MODULE__{
            outcome: outcome(),
            value: term(),
            state: %{binary() => binary()},
            journal: list(),
            run_completions: %{integer() => term()},
            iterations: pos_integer()
          }
  end

  @type opts :: [
          {:state, %{binary() => binary()}}
          | {:partial_state, boolean()}
          | {:key, binary()}
          | {:start_id, binary()}
          | {:max_iterations, pos_integer()}
          | {:call_responses, map()}
        ]

  @max_iterations 64

  @doc """
  Drive a handler to its terminal outcome.

  ## Options

    * `:state` — initial state map, `%{binary() => binary()}`. Both
      keys and values are bytes (the on-wire representation). For
      JSON-encoded values, encode yourself: `Jason.encode!(value)`.
    * `:partial_state` — `false` (default) means the handler sees
      the full state map eagerly. `true` exercises the lazy-state
      protocol path: missing keys trigger `GetLazyState` round-trips,
      which this runtime serves from the same `:state` opt.
    * `:key` — `StartMessage.key` for the invocation. Required for
      VirtualObject / Workflow handlers that read it via
      `Restate.Context.key/1`.
    * `:start_id` — `StartMessage.id`, defaults to a fixed test id.
    * `:random_seed` — V6 `StartMessage.random_seed`. Defaults to 0
      (V5 behaviour: handler `:rand` state inherits BEAM's default
      non-deterministic seeding). Set to a non-zero `uint64` to seed
      the handler process deterministically, mirroring what
      `restate-server` does on a V6-negotiated invocation.
    * `:max_iterations` — safety cap on the suspend-resume loop.
      Default #{@max_iterations}.
    * `:call_responses` — `%{{service, handler} => term() | (params -> term())}`.
      Required if the handler uses `ctx.call`. Functions receive the
      raw parameter bytes the SDK serialised; static terms are
      JSON-encoded and returned as-is.
  """
  @spec run({module(), atom(), arity()}, term(), opts()) :: Result.t()
  def run(mfa, input \\ nil, opts \\ []) do
    state_init = Keyword.get(opts, :state, %{})
    start_id = Keyword.get(opts, :start_id, <<0, 1, 2, 3>>)
    key = Keyword.get(opts, :key, "")
    partial_state? = Keyword.get(opts, :partial_state, false)
    max_iter = Keyword.get(opts, :max_iterations, @max_iterations)
    random_seed = Keyword.get(opts, :random_seed, 0)

    # In `partial_state: true` mode, no key is eagerly bundled into
    # the StartMessage — the SDK falls through to GetLazyState for
    # every read, and this runtime serves them from `state_init`.
    # In eager mode, the full state goes in the StartMessage and the
    # SDK never emits lazy reads.
    state_entries =
      if partial_state?, do: [], else: state_to_entries(state_init)

    config = %{
      mfa: mfa,
      input: input,
      start_id: start_id,
      state_entries: state_entries,
      key: key,
      partial_state: partial_state?,
      initial_state: state_init,
      call_responses: Keyword.get(opts, :call_responses, %{}),
      max_iterations: max_iter,
      random_seed: random_seed
    }

    do_run(config, [], [], %{}, 0)
  end

  defp do_run(%{max_iterations: max}, _, _, _, depth) when depth >= max do
    raise """
    Restate.Test.FakeRuntime: handler did not reach a terminal outcome \
    within #{max} suspend-resume iterations. Either the handler is in \
    an infinite loop, or the runtime synthesised a wrong completion. \
    Bump :max_iterations if the handler is genuinely long.
    """
  end

  defp do_run(config, replay_messages, commands_acc, completions_acc, depth) do
    {outcome, body} = invoke(config, replay_messages)
    messages = decode!(body)
    new_commands = extract_journal_commands(messages)
    new_completions = extract_run_completions(messages)
    combined_commands = commands_acc ++ new_commands
    combined_completions = Map.merge(completions_acc, new_completions)

    case outcome do
      :suspended ->
        suspension = find_suspension(messages)

        notifications =
          resolve_suspension(suspension, combined_commands, combined_completions, config)

        next_replay = replay_messages ++ new_commands ++ notifications

        do_run(config, next_replay, combined_commands, combined_completions, depth + 1)

      _terminal ->
        terminal_value = extract_terminal_value(messages, outcome)

        %Result{
          outcome: outcome,
          value: terminal_value,
          state: derive_state(config.initial_state, combined_commands),
          journal: combined_commands ++ messages,
          run_completions: combined_completions,
          iterations: depth + 1
        }
    end
  end

  # --- invocation helpers ---

  defp invoke(config, replay_messages) do
    start = %Pb.StartMessage{
      id: config.start_id,
      debug_id: "fake-runtime",
      known_entries: 1,
      state_map: config.state_entries,
      partial_state: config.partial_state,
      key: config.key,
      random_seed: config.random_seed
    }

    replay_frames =
      Enum.map(replay_messages, fn msg ->
        %Frame{type: 0, flags: 0, message: msg}
      end)

    {:ok, pid} =
      Invocation.start_link({start, config.input, replay_frames, config.mfa, %{}})

    Invocation.await_response(pid)
  end

  defp decode!(body), do: decode_body(body)

  # `*CommandMessage` (excluding `OutputCommandMessage`, which is
  # terminal). These are what the runtime would persist as the
  # replayable journal.
  @doc false
  def extract_journal_commands(messages) do
    Enum.filter(messages, fn %mod{} = msg ->
      name = Atom.to_string(mod)

      String.ends_with?(name, "CommandMessage") and
        not is_struct(msg, Pb.OutputCommandMessage)
    end)
  end

  @doc false
  def extract_run_completions(messages) do
    messages
    |> Enum.flat_map(fn
      %Pb.ProposeRunCompletionMessage{result_completion_id: cid, result: result} ->
        [{cid, result}]

      _ ->
        []
    end)
    |> Map.new()
  end

  defp find_suspension(messages) do
    Enum.find(messages, &match?(%Pb.SuspensionMessage{}, &1))
  end

  @doc """
  Distil the terminal frame in a list of decoded messages to a
  comparable Elixir term. Public so `Restate.Test.CrashInjection`
  can reuse it: same extraction function on both sides means
  baseline and prefix-replay values compare with `==`.
  """
  @spec extract_terminal_value([struct()], Result.outcome() | :suspended) :: term()
  def extract_terminal_value(messages, :value) do
    Enum.find_value(messages, fn
      %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: bytes}}} ->
        decode_payload(bytes)

      _ ->
        nil
    end)
  end

  def extract_terminal_value(messages, :terminal_failure) do
    Enum.find_value(messages, fn
      %Pb.OutputCommandMessage{result: {:failure, %Pb.Failure{} = f}} ->
        %Restate.TerminalError{
          code: f.code,
          message: f.message,
          metadata: failure_metadata(f.metadata)
        }

      _ ->
        nil
    end)
  end

  def extract_terminal_value(messages, :error) do
    Enum.find_value(messages, fn
      %Pb.ErrorMessage{} = e -> e
      _ -> nil
    end)
  end

  def extract_terminal_value(messages, :journal_mismatch) do
    extract_terminal_value(messages, :error)
  end

  def extract_terminal_value(messages, :suspended) do
    Enum.find_value(messages, fn
      %Pb.SuspensionMessage{waiting_completions: comps, waiting_signals: sigs} ->
        {:suspended, comps || [], sigs || []}

      _ ->
        nil
    end)
  end

  @doc """
  Decode a framed wire body to a list of protobuf message structs.
  Public so `Restate.Test.CrashInjection` can decode prefix-replay
  responses without duplicating the helper.
  """
  @spec decode_body(binary()) :: [struct()]
  def decode_body(body) when is_binary(body) do
    {:ok, frames, ""} = Framer.decode_all(body)
    Enum.map(frames, & &1.message)
  end

  defp decode_payload(bytes) when is_binary(bytes), do: Restate.Serde.decode(bytes)

  defp failure_metadata(nil), do: %{}

  defp failure_metadata(metadata) when is_list(metadata) do
    Enum.into(metadata, %{}, fn %Pb.FailureMetadata{key: k, value: v} -> {k, v} end)
  end

  # --- suspension resolution ---

  # For each waiting completion id and each waiting signal id (other
  # than CANCEL), produce the notification the runtime would have
  # delivered. Raises a descriptive error for shapes we don't yet
  # support — no silent hangs.
  defp resolve_suspension(suspension, commands, completions, config) do
    waiting = (suspension && suspension.waiting_completions) || []
    waiting_signals = (suspension && suspension.waiting_signals) || []

    awakeable_signals = Enum.reject(waiting_signals, &(&1 == 1))

    if awakeable_signals != [] do
      raise """
      Restate.Test.FakeRuntime: handler is waiting on awakeable signal \
      ids #{inspect(awakeable_signals)}, but awakeable completions are \
      not yet supported by the v0 runtime. To test awakeable-using \
      handlers, drive them through the HTTP endpoint with a real or \
      mocked Restate runtime.
      """
    end

    cmd_index = index_commands_by_cid(commands)

    Enum.map(waiting, fn cid ->
      resolve_cid(cid, cmd_index, completions, config)
    end)
  end

  defp resolve_cid(cid, cmd_index, completions, config) do
    case Map.fetch(cmd_index, cid) do
      {:ok, {:sleep, _cmd}} ->
        %Pb.SleepCompletionNotificationMessage{completion_id: cid, void: %Pb.Void{}}

      {:ok, {:run, _cmd}} ->
        case Map.fetch(completions, cid) do
          {:ok, propose_result} ->
            %Pb.RunCompletionNotificationMessage{
              completion_id: cid,
              result: propose_to_notification_result(propose_result)
            }

          :error ->
            raise """
            Restate.Test.FakeRuntime: ctx.run on cid #{cid} did not \
            emit a ProposeRunCompletion in the same iteration. This \
            usually means the SDK suspended before the user function \
            ran, which shouldn't happen.
            """
        end

      {:ok, {:lazy_state, cmd}} ->
        case Map.fetch(config.initial_state, cmd.key) do
          {:ok, bytes} when is_binary(bytes) ->
            %Pb.GetLazyStateCompletionNotificationMessage{
              completion_id: cid,
              result: {:value, %Pb.Value{content: bytes}}
            }

          :error ->
            %Pb.GetLazyStateCompletionNotificationMessage{
              completion_id: cid,
              result: {:void, %Pb.Void{}}
            }
        end

      {:ok, {:lazy_state_keys, _cmd}} ->
        keys = Map.keys(config.initial_state)

        %Pb.GetLazyStateKeysCompletionNotificationMessage{
          completion_id: cid,
          state_keys: %Pb.StateKeys{keys: keys}
        }

      {:ok, {:call_invocation_id, _cmd}} ->
        %Pb.CallInvocationIdCompletionNotificationMessage{
          completion_id: cid,
          invocation_id: "fake-inv-#{cid}"
        }

      {:ok, {:call_result, cmd}} ->
        resolve_call_response(cid, cmd, config)

      {:ok, {:promise_get, _cmd}} ->
        raise """
        Restate.Test.FakeRuntime: handler is suspended on \
        get_promise (cid #{cid}). Workflow promises are not yet \
        supported by the v0 runtime.
        """

      {:ok, {:promise_peek, _cmd}} ->
        raise "Restate.Test.FakeRuntime: peek_promise not yet supported (cid #{cid})"

      {:ok, {:promise_complete, _cmd}} ->
        raise "Restate.Test.FakeRuntime: complete_promise not yet supported (cid #{cid})"

      {:ok, {kind, _cmd}} ->
        raise "Restate.Test.FakeRuntime: unhandled suspension kind #{inspect(kind)} on cid #{cid}"

      :error ->
        raise """
        Restate.Test.FakeRuntime: handler suspended on cid #{cid} but \
        no matching command exists in the journal. This may indicate a \
        protocol bug or a corrupt prior iteration.
        """
    end
  end

  defp resolve_call_response(cid, %Pb.CallCommandMessage{} = cmd, config) do
    key = {cmd.service_name, cmd.handler_name}

    case Map.fetch(config.call_responses, key) do
      {:ok, fun} when is_function(fun, 1) ->
        value = fun.(cmd.parameter)
        encoded = Restate.Serde.encode(value)

        %Pb.CallCompletionNotificationMessage{
          completion_id: cid,
          result: {:value, %Pb.Value{content: encoded}}
        }

      {:ok, value} ->
        encoded = Restate.Serde.encode(value)

        %Pb.CallCompletionNotificationMessage{
          completion_id: cid,
          result: {:value, %Pb.Value{content: encoded}}
        }

      :error ->
        raise """
        Restate.Test.FakeRuntime: handler called #{cmd.service_name}/#{cmd.handler_name} \
        but no response was provided. Add it to opts:

            call_responses: %{
              {"#{cmd.service_name}", "#{cmd.handler_name}"} => fn _params_bytes -> ... end
            }

        Or pass a static value:

            call_responses: %{{"#{cmd.service_name}", "#{cmd.handler_name}"} => 42}
        """
    end
  end

  defp propose_to_notification_result({:value, bytes}) when is_binary(bytes) do
    {:value, %Pb.Value{content: bytes}}
  end

  defp propose_to_notification_result({:failure, %Pb.Failure{} = f}) do
    {:failure, f}
  end

  # --- command indexing ---

  # Build %{cid => {kind, command}} from the journal so suspension
  # resolution is O(1) per cid. A single CallCommandMessage indexes
  # twice (under both result_completion_id and
  # invocation_id_notification_idx) since either may be the cid the
  # handler is waiting on.
  defp index_commands_by_cid(commands) do
    Enum.reduce(commands, %{}, fn cmd, acc ->
      acc
      |> maybe_index(cmd, :result_completion_id, &result_kind/1)
      |> maybe_index(cmd, :invocation_id_notification_idx, &invocation_kind/1)
    end)
  end

  defp maybe_index(acc, cmd, field, kind_fn) do
    case Map.get(cmd, field) do
      nil ->
        acc

      0 ->
        # Protobuf default for unset uint32 — not a real cid.
        acc

      cid when is_integer(cid) ->
        Map.put(acc, cid, {kind_fn.(cmd), cmd})
    end
  end

  defp result_kind(%Pb.SleepCommandMessage{}), do: :sleep
  defp result_kind(%Pb.RunCommandMessage{}), do: :run
  defp result_kind(%Pb.GetLazyStateCommandMessage{}), do: :lazy_state
  defp result_kind(%Pb.GetLazyStateKeysCommandMessage{}), do: :lazy_state_keys
  defp result_kind(%Pb.CallCommandMessage{}), do: :call_result
  defp result_kind(%Pb.GetPromiseCommandMessage{}), do: :promise_get
  defp result_kind(%Pb.PeekPromiseCommandMessage{}), do: :promise_peek
  defp result_kind(%Pb.CompletePromiseCommandMessage{}), do: :promise_complete
  defp result_kind(%mod{}), do: {:unknown_result, mod}

  defp invocation_kind(%Pb.CallCommandMessage{}), do: :call_invocation_id
  defp invocation_kind(%Pb.OneWayCallCommandMessage{}), do: :call_invocation_id
  defp invocation_kind(%mod{}), do: {:unknown_invocation_id, mod}

  # --- state derivation ---

  # Apply the state-mutating commands in journal order to the initial
  # state to derive the final state.
  defp derive_state(initial, commands) do
    Enum.reduce(commands, initial, fn
      %Pb.SetStateCommandMessage{key: k, value: %Pb.Value{content: bytes}}, acc ->
        Map.put(acc, k, bytes)

      %Pb.ClearStateCommandMessage{key: k}, acc ->
        Map.delete(acc, k)

      %Pb.ClearAllStateCommandMessage{}, _acc ->
        %{}

      _, acc ->
        acc
    end)
  end

  defp state_to_entries(state) do
    Enum.map(state, fn {k, v} -> %Pb.StartMessage.StateEntry{key: k, value: v} end)
  end
end
