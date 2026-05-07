defmodule Restate.Server.Invocation do
  @moduledoc """
  One process per HTTP invocation. Implements the V5/V6 state machine:
  `:replaying` while there are recorded journal commands to consume,
  `:processing` once the handler has caught up to the head of the journal.
  V5 and V6 share the same command/notification wire shape; V6 adds
  `StartMessage.random_seed` (used to seed `:rand` in the handler
  process for `Restate.Context.random_*`) and an official
  `Failure.metadata` field (already supported under V5).

  ## Lifecycle

      Endpoint → Invocation.start_link({start, input, replay_journal, mfa, dispatch_meta})
        ├─ Invocation partitions the post-Input replay frames:
        │     • recorded_commands (Set/Sleep/Output/...) — in order
        │     • notifications     — %{completion_id => :void | term}
        ├─ Invocation spawns the user handler in a linked process,
        │  passing it a `Restate.Context` whose pid is the Invocation
        ├─ Each Context call (`get_state`, `set_state`, `sleep`) is a
        │  synchronous GenServer.call:
        │     • In :replaying — pop the next recorded command, validate
        │       its type, do NOT re-emit. For completable commands
        │       (Sleep): if the matching completion is in the table,
        │       reply :ok. Otherwise, suspend.
        │     • In :processing — emit a fresh command. For completable
        │       commands without local completion, suspend immediately
        │       (REQUEST_RESPONSE mode — no completions arrive on this
        │       stream).
        └─ Handler returns / raises / process is killed → finalize the
           framed response (Output|Error|Suspension + optional End)

  ## Suspension

  When the handler blocks on a completable command whose result we don't
  have, we emit a `SuspensionMessage{ waiting_completions: [id] }`,
  terminate the handler process, and close the response without an
  `EndMessage`. The runtime persists the journal so far and re-invokes
  later when the completion arrives.
  """

  use GenServer

  alias Dev.Restate.Service.Protocol, as: Pb
  alias Restate.Protocol.{Frame, Framer}

  @doc """
  Start an invocation.

  `replay_journal` is the list of `%Restate.Protocol.Frame{}` entries
  after the leading `StartMessage` and `InputCommandMessage` — i.e. the
  recorded journal the runtime is replaying.

  `mfa` is `{module, function, arity}` — the function is called with
  `(%Restate.Context{}, input_value)`.

  `dispatch_meta` is a `%{service: binary(), handler: binary()}` map
  used as `:telemetry` metadata. Pass `%{}` from non-HTTP contexts
  (tests) when the values aren't meaningful.
  """
  @spec start_link(
          {Pb.StartMessage.t(), term(), [Frame.t()], {module(), atom(), arity()}, map()}
        ) :: GenServer.on_start()
  def start_link(
        {%Pb.StartMessage{}, _input, replay_journal, _mfa, dispatch_meta} = arg
      )
      when is_list(replay_journal) and is_map(dispatch_meta) do
    GenServer.start_link(__MODULE__, arg)
  end

  @typedoc """
  Outcome tag returned by `await_response/2`. `:value` and
  `:terminal_failure` are normal handler completions (the latter with
  an `OutputCommandMessage{failure}` body); `:error` is a generic
  exception that escaped the handler; `:suspended` means the runtime
  must re-invoke us when a completion arrives; `:journal_mismatch` is
  protocol code 570.
  """
  @type outcome ::
          :value | :terminal_failure | :error | :suspended | :journal_mismatch

  @doc """
  Block until the handler completes (or suspends, or raises) and return
  `{outcome, framed_response_body}`. Stops the invocation process on
  return.
  """
  @spec await_response(pid(), timeout()) :: {outcome(), binary()}
  def await_response(pid, timeout \\ 30_000) do
    GenServer.call(pid, :await_response, timeout)
  end

  # --- GenServer ---

  @impl true
  def init({%Pb.StartMessage{} = start, input, replay_journal, mfa, dispatch_meta}) do
    %Pb.StartMessage{
      id: start_message_id,
      state_map: state_entries,
      key: object_key,
      partial_state: partial_state?,
      # `random_seed` is a V6 addition (`uint64`, field 9). Under V5
      # the runtime leaves it at the default 0; under V6 it carries
      # a stable per-invocation seed used to seed the handler
      # process's `:rand` state so `Restate.Context.random_*` is
      # deterministic across replays.
      random_seed: random_seed
    } = start

    state_map =
      for %Pb.StartMessage.StateEntry{key: k, value: v} <- state_entries, into: %{} do
        {k, v}
      end

    {recorded_commands, notifications, signal_notifications, cancelled?} =
      partition_journal(replay_journal)

    initial_completion_id = max_completion_id_seen(replay_journal) + 1
    # Signal ids are allocator-deterministic: every replay must reproduce
    # the same signal_id sequence as the first execution. Java's
    # Journal.signalIndex resets to 17 on every invocation; we do the
    # same. (1–16 are reserved for built-in signals like cancel.)
    # Don't seed from the journal — the journal's signal notifications
    # are the *result* of allocations, not their source of truth.
    initial_signal_id = 17

    # Register with the DrainCoordinator so SIGTERM-triggered drain can
    # wait for us to finish before stopping the BEAM. No-op when the
    # coordinator isn't running (e.g. in test envs that don't boot it).
    Restate.Server.DrainCoordinator.register(self())

    parent = self()

    handler_pid =
      spawn_link(fn ->
        # Seed `:rand` in the handler process so `Restate.Context.random_*`
        # produces the same stream on every replay (`random_seed` is
        # the same in every StartMessage for this invocation under V6).
        # Under V5 the seed is 0 and we skip seeding — `Context.random_*`
        # callers will still get *a* number, but it'll be the BEAM's
        # default non-deterministic seed and replays will diverge. The
        # SDK README documents that `Context.random_*` requires V6.
        if is_integer(random_seed) and random_seed > 0 do
          :rand.seed(:exsss, random_seed)
        end

        ctx = %Restate.Context{pid: parent, key: object_key || ""}
        {mod, fun, _arity} = mfa

        result =
          try do
            {:ok, apply(mod, fun, [ctx, input])}
          rescue
            e -> {:error, e, __STACKTRACE__}
          end

        send(parent, {:handler_result, result})
      end)

    phase = if recorded_commands == [], do: :processing, else: :replaying

    {:ok,
     %{
       phase: phase,
       # Snapshotted at init so `:replay_complete` can report how many
       # recorded commands existed when this invocation started.
       replay_journal_size: length(recorded_commands),
       # Flipped to true the one time `advance_phase/1` transitions us
       # from `:replaying` to `:processing`. Reported in the `:stop`
       # event metadata so dashboards can distinguish first-run from
       # resumption invocations.
       replay_phase_completed?: false,
       # `%{service: binary, handler: binary}` for telemetry metadata.
       # Endpoint populates it; tests may pass `%{}` when service /
       # handler don't matter.
       dispatch_meta: dispatch_meta,
       # Set at every `finalize/3` site to one of the values in the
       # `outcome` typedoc. Returned alongside the wire body from
       # `await_response/2` and reported in `:stop` event metadata.
       outcome: nil,
       state_map: state_map,
       # `StartMessage.partial_state` true means the runtime did not
       # bundle every state value into the eager `state_map` —
       # missing keys must be fetched via `GetLazyStateCommandMessage`.
       # `nil` in `state_map` is the "fetched and absent" / "cleared"
       # sentinel; `Map.fetch/2` distinguishes it from missing-from-map.
       partial_state?: partial_state?,
       state_keys_cache: nil,
       start_id: start_message_id,
       recorded_commands: recorded_commands,
       notifications: notifications,
       signal_notifications: signal_notifications,
       next_completion_id: initial_completion_id,
       next_signal_id: initial_signal_id,
       # Built-in CANCEL signal (signal_id = 1, per BuiltInSignal in
       # protocol.proto:670). Once true, every subsequent suspending
       # Context op raises Restate.TerminalError{code: 409}. Mirrors
       # Java's `AsyncResultsState` reserving NotificationHandle 1 for
       # the cancel signal.
       cancelled?: cancelled?,
       emitted: [],
       # Tracking for ErrorMessage.related_command_* fields (mirrors
       # Java's Journal.lastCommandMetadata). Index starts at -1
       # meaning "no command processed yet"; advances on each
       # consume_command/2 call (replay or fresh emit).
       current_command: %{index: -1, name: nil, type: nil},
       awaiting_response: nil,
       result_body: nil,
       handler_pid: handler_pid
     }}
  end

  @impl true
  def handle_call({:get_state, key}, from, state) do
    case Map.fetch(state.state_map, key) do
      {:ok, nil} ->
        # Sentinel: explicitly cleared in this invocation, OR previously
        # lazy-fetched and confirmed absent.
        {:reply, nil, state}

      {:ok, bytes} when is_binary(bytes) ->
        {:reply, bytes, state}

      :error ->
        if state.partial_state? do
          do_lazy_get_state(state, key, from)
        else
          # Eager state is the source of truth — missing means absent.
          {:reply, nil, state}
        end
    end
  end

  @impl true
  def handle_call({:set_state, key, value_bytes}, from, state) do
    cmd = %Pb.SetStateCommandMessage{key: key, value: %Pb.Value{content: value_bytes}}
    state = %{state | state_map: Map.put(state.state_map, key, value_bytes)}

    case state.phase do
      :replaying ->
        # In replay we do NOT re-emit; we only consume the next recorded
        # command and validate it's a SetStateCommandMessage.
        with {:ok, {recorded, rest}} <- pop_recorded(state.recorded_commands, Pb.SetStateCommandMessage) do
          state = state |> Map.put(:recorded_commands, rest) |> track_command(recorded)
          {:reply, :ok, advance_phase(state)}
        else
          {:error, exc} -> finalize_journal_mismatch(state, exc, from)
        end

      :processing ->
        state = state |> Map.update!(:emitted, &[cmd | &1]) |> track_command(cmd)
        {:reply, :ok, state}
    end
  end

  def handle_call(:clear_all_state, from, state) do
    cmd = %Pb.ClearAllStateCommandMessage{}
    # After clear_all the runtime has nothing — flip partial_state? to
    # false so subsequent get_state returns nil locally without a wasted
    # GetLazyStateCommand round-trip.
    state = %{state | state_map: %{}, state_keys_cache: [], partial_state?: false}

    case state.phase do
      :replaying ->
        with {:ok, {recorded, rest}} <- pop_recorded(state.recorded_commands, Pb.ClearAllStateCommandMessage) do
          state = state |> Map.put(:recorded_commands, rest) |> track_command(recorded)
          {:reply, :ok, advance_phase(state)}
        else
          {:error, exc} -> finalize_journal_mismatch(state, exc, from)
        end

      :processing ->
        state = state |> Map.update!(:emitted, &[cmd | &1]) |> track_command(cmd)
        {:reply, :ok, state}
    end
  end

  def handle_call(:state_keys, from, state) do
    cond do
      state.partial_state? and state.state_keys_cache == nil ->
        do_lazy_state_keys(state, from)

      true ->
        {:reply, current_state_keys(state), state}
    end
  end

  def handle_call({:clear_state, key}, from, state) do
    cmd = %Pb.ClearStateCommandMessage{key: key}
    # nil sentinel = "explicitly cleared" — survives subsequent
    # `get_state` without re-fetching from the runtime.
    state = %{state | state_map: Map.put(state.state_map, key, nil)}

    case state.phase do
      :replaying ->
        with {:ok, {recorded, rest}} <- pop_recorded(state.recorded_commands, Pb.ClearStateCommandMessage) do
          state = state |> Map.put(:recorded_commands, rest) |> track_command(recorded)
          {:reply, :ok, advance_phase(state)}
        else
          {:error, exc} -> finalize_journal_mismatch(state, exc, from)
        end

      :processing ->
        state = state |> Map.update!(:emitted, &[cmd | &1]) |> track_command(cmd)
        {:reply, :ok, state}
    end
  end

  def handle_call({:call, target}, from, state) do
    case state.phase do
      :replaying ->
        with {:ok, {recorded, rest}} <- pop_recorded(state.recorded_commands, Pb.CallCommandMessage) do
          state = state |> Map.put(:recorded_commands, rest) |> track_command(recorded) |> advance_phase()
          handle_call_result(state, recorded, from)
        else
          {:error, exc} -> finalize_journal_mismatch(state, exc, from)
        end

      :processing ->
        cid_invok = state.next_completion_id
        cid_result = cid_invok + 1

        cmd = %Pb.CallCommandMessage{
          service_name: target.service,
          handler_name: target.handler,
          parameter: target.parameter,
          key: target.key || "",
          idempotency_key: target.idempotency_key,
          invocation_id_notification_idx: cid_invok,
          result_completion_id: cid_result
        }

        state =
          state
          |> Map.update!(:emitted, &[cmd | &1])
          |> Map.put(:next_completion_id, cid_result + 1)
          |> track_command(cmd)

        if state.cancelled? do
          # No invocation_id available yet (the runtime hasn't started
          # the callee), so we can't propagate cancel to it from here.
          # The callee will appear on the next replay's journal; that
          # replay won't re-emit this CallCommand though, so we'll
          # never get the chance. Restate's runtime is responsible for
          # not spawning callees of an already-failed invocation.
          {:reply, {:terminal_error, cancellation_error()}, state}
        else
          # REQUEST_RESPONSE: the result notification arrives on a
          # subsequent invocation, so we suspend on cid_result.
          suspend(state, cid_result, from)
        end
    end
  end

  def handle_call({:send_async, target}, from, state) do
    case state.phase do
      :replaying ->
        with {:ok, {recorded, rest}} <- pop_recorded(state.recorded_commands, Pb.OneWayCallCommandMessage) do
          state = state |> Map.put(:recorded_commands, rest) |> track_command(recorded) |> advance_phase()
          {:reply, :ok, state}
        else
          {:error, exc} -> finalize_journal_mismatch(state, exc, from)
        end

      :processing ->
        cid_invok = state.next_completion_id

        cmd = %Pb.OneWayCallCommandMessage{
          service_name: target.service,
          handler_name: target.handler,
          parameter: target.parameter,
          key: target.key || "",
          idempotency_key: target.idempotency_key,
          invoke_time: target.invoke_at_ms || 0,
          invocation_id_notification_idx: cid_invok
        }

        state =
          state
          |> Map.update!(:emitted, &[cmd | &1])
          |> Map.put(:next_completion_id, cid_invok + 1)
          |> track_command(cmd)

        # Fire-and-forget: do NOT suspend on the invocation_id
        # notification. The notification will arrive in some future
        # journal but we won't observe it. This is what makes
        # high-concurrency fan-out viable — N send_asyncs cost N
        # journal entries, not N HTTP round-trips.
        {:reply, :ok, state}
    end
  end

  def handle_call({:send, target}, from, state) do
    case state.phase do
      :replaying ->
        with {:ok, {recorded, rest}} <- pop_recorded(state.recorded_commands, Pb.OneWayCallCommandMessage) do
          state = state |> Map.put(:recorded_commands, rest) |> track_command(recorded) |> advance_phase()
          handle_send_invocation_id(state, recorded.invocation_id_notification_idx, from)
        else
          {:error, exc} -> finalize_journal_mismatch(state, exc, from)
        end

      :processing ->
        cid_invok = state.next_completion_id

        cmd = %Pb.OneWayCallCommandMessage{
          service_name: target.service,
          handler_name: target.handler,
          parameter: target.parameter,
          key: target.key || "",
          idempotency_key: target.idempotency_key,
          invoke_time: target.invoke_at_ms || 0,
          invocation_id_notification_idx: cid_invok
        }

        state =
          state
          |> Map.update!(:emitted, &[cmd | &1])
          |> Map.put(:next_completion_id, cid_invok + 1)
          |> track_command(cmd)

        if state.cancelled? do
          {:reply, {:terminal_error, cancellation_error()}, state}
        else
          # We block on the invocation_id notification so callers can
          # use the spawned invocation's id (e.g. Proxy.oneWayCall
          # returns it). REQUEST_RESPONSE mode: arrives on next replay.
          suspend(state, cid_invok, from)
        end
    end
  end

  def handle_call(:awakeable, _from, state) do
    # No journal entry — awakeables are pure signal_id allocations on
    # the SDK side. The id encodes (start_message_id, signal_id) so
    # external completers can route to us; we just need to remember
    # which signal_id we allocated for the await.
    signal_id = state.next_signal_id

    awakeable_id = encode_awakeable_id(state.start_id, signal_id)

    {:reply, {:ok, {awakeable_id, signal_id}},
     %{state | next_signal_id: signal_id + 1}}
  end

  def handle_call({:await_awakeable, signal_id}, from, state) do
    case Map.fetch(state.signal_notifications, signal_id) do
      {:ok, {:value, %Pb.Value{content: bytes}}} ->
        {:reply, {:ok, decode_response(bytes)}, state}

      {:ok, {:failure, %Pb.Failure{code: code, message: message, metadata: meta}}} ->
        exc = %Restate.TerminalError{
          code: code,
          message: message,
          metadata: decode_failure_metadata(meta)
        }

        {:reply, {:terminal_error, exc}, state}

      {:ok, _other} ->
        # Void or other shapes — return nil to mirror "completed without payload".
        {:reply, {:ok, nil}, state}

      :error ->
        # Awaiting a signal that hasn't fired. If we're cancelled, this
        # is the await site that picks up the cancellation — mirrors
        # Java's "cancel raises at the next blocking op." A handler
        # that's already past every blocking op (or whose every blocking
        # op already has a completion in the journal) is allowed to
        # finish normally.
        if state.cancelled? do
          {:reply, {:terminal_error, cancellation_error()}, state}
        else
          # Suspend on the signal_id; SuspensionMessage carries it in
          # `waiting_signals` rather than `waiting_completions`.
          suspend_signal(state, signal_id, from)
        end
    end
  end

  def handle_call({:send_signal, target_invocation_id, signal_id}, from, state)
      when is_binary(target_invocation_id) and is_integer(signal_id) do
    cmd = %Pb.SendSignalCommandMessage{
      target_invocation_id: target_invocation_id,
      signal_id: {:idx, signal_id},
      result: {:void, %Pb.Void{}}
    }

    case state.phase do
      :replaying ->
        with {:ok, {recorded, rest}} <-
               pop_recorded(state.recorded_commands, Pb.SendSignalCommandMessage) do
          state = state |> Map.put(:recorded_commands, rest) |> track_command(recorded)
          {:reply, :ok, advance_phase(state)}
        else
          {:error, exc} -> finalize_journal_mismatch(state, exc, from)
        end

      :processing ->
        # SendSignal is "Completable: No" per protocol.proto:482 — fire
        # and forget, no completion ever arrives. We do not check
        # cancellation here: a handler that's been cancelled mid-tree
        # may still want to issue cancels to its children before
        # exiting.
        state = state |> Map.update!(:emitted, &[cmd | &1]) |> track_command(cmd)
        {:reply, :ok, state}
    end
  end

  def handle_call({:complete_awakeable, awakeable_id, completion}, from, state)
      when is_binary(awakeable_id) do
    cmd = build_complete_awakeable(awakeable_id, completion)

    case state.phase do
      :replaying ->
        with {:ok, {recorded, rest}} <-
               pop_recorded(state.recorded_commands, Pb.CompleteAwakeableCommandMessage) do
          state = state |> Map.put(:recorded_commands, rest) |> track_command(recorded)
          {:reply, :ok, advance_phase(state)}
        else
          {:error, exc} -> finalize_journal_mismatch(state, exc, from)
        end

      :processing ->
        state = state |> Map.update!(:emitted, &[cmd | &1]) |> track_command(cmd)
        {:reply, :ok, state}
    end
  end

  def handle_call(:start_run, from, state) do
    case state.phase do
      :replaying ->
        with {:ok, {recorded, rest}} <- pop_recorded(state.recorded_commands, Pb.RunCommandMessage) do
          state = state |> Map.put(:recorded_commands, rest) |> track_command(recorded) |> advance_phase()

          case Map.fetch(state.notifications, recorded.result_completion_id) do
            {:ok, {:value, %Pb.Value{content: bytes}}} ->
              # Replayed values stand even if cancel arrived this
              # cycle — the side effect already happened in a previous
              # invocation, the journal is the truth.
              {:reply, {:replay_value, decode_response(bytes)}, state}

            {:ok, {:failure, %Pb.Failure{code: code, message: message, metadata: meta}}} ->
              metadata_map = decode_failure_metadata(meta)
              exc = %Restate.TerminalError{code: code, message: message, metadata: metadata_map}
              {:reply, {:replay_failure, exc}, state}

            :error ->
              # Run command in journal but no notification yet — the
              # propose from a previous invocation didn't commit. Skip
              # re-execution if cancelled so the side-effect doesn't
              # run after the user asked us to stop.
              if state.cancelled? do
                {:reply, {:terminal_error, cancellation_error()}, state}
              else
                {:reply, {:execute, recorded.result_completion_id}, state}
              end
          end
        else
          {:error, exc} -> finalize_journal_mismatch(state, exc, from)
        end

      :processing ->
        cid = state.next_completion_id

        cmd = %Pb.RunCommandMessage{result_completion_id: cid}

        state =
          state
          |> Map.update!(:emitted, &[cmd | &1])
          |> Map.put(:next_completion_id, cid + 1)
          |> track_command(cmd)

        if state.cancelled? do
          # Don't run the side-effecting function. The journal
          # carries the RunCommand but no completion will arrive,
          # which is fine — the invocation is terminating with
          # OutputCommandMessage{failure} on the next pass.
          {:reply, {:terminal_error, cancellation_error()}, state}
        else
          {:reply, {:execute, cid}, state}
        end
    end
  end

  # --- Workflow durable promises ---
  #
  # `promise_get` blocks the workflow on a named durable promise (the
  # promise is keyed by the workflow's StartMessage.key implicitly;
  # `name` here is the promise label within that key's namespace).
  # `promise_peek` is a non-blocking probe — the runtime always
  # responds, with Void if the promise is unresolved or Value/Failure
  # if it is. `promise_complete` resolves the promise from another
  # handler (typically a @Shared handler running on the same workflow
  # key). All three follow the same suspend-on-completion shape as
  # ctx.sleep / ctx.call in REQUEST_RESPONSE mode.

  def handle_call({:promise_get, name}, from, state) when is_binary(name) do
    case state.phase do
      :replaying ->
        with {:ok, {recorded, rest}} <-
               pop_recorded(state.recorded_commands, Pb.GetPromiseCommandMessage) do
          state = state |> Map.put(:recorded_commands, rest) |> track_command(recorded) |> advance_phase()
          handle_promise_value_result(state, recorded.result_completion_id, from)
        else
          {:error, exc} -> finalize_journal_mismatch(state, exc, from)
        end

      :processing ->
        cid = state.next_completion_id
        cmd = %Pb.GetPromiseCommandMessage{key: name, result_completion_id: cid}

        state =
          state
          |> Map.update!(:emitted, &[cmd | &1])
          |> Map.put(:next_completion_id, cid + 1)
          |> track_command(cmd)

        if state.cancelled? do
          {:reply, {:terminal_error, cancellation_error()}, state}
        else
          suspend(state, cid, from)
        end
    end
  end

  def handle_call({:promise_peek, name}, from, state) when is_binary(name) do
    case state.phase do
      :replaying ->
        with {:ok, {recorded, rest}} <-
               pop_recorded(state.recorded_commands, Pb.PeekPromiseCommandMessage) do
          state = state |> Map.put(:recorded_commands, rest) |> track_command(recorded) |> advance_phase()
          handle_promise_peek_result(state, recorded.result_completion_id, from)
        else
          {:error, exc} -> finalize_journal_mismatch(state, exc, from)
        end

      :processing ->
        cid = state.next_completion_id
        cmd = %Pb.PeekPromiseCommandMessage{key: name, result_completion_id: cid}

        state =
          state
          |> Map.update!(:emitted, &[cmd | &1])
          |> Map.put(:next_completion_id, cid + 1)
          |> track_command(cmd)

        if state.cancelled? do
          {:reply, {:terminal_error, cancellation_error()}, state}
        else
          suspend(state, cid, from)
        end
    end
  end

  def handle_call({:promise_complete, name, completion}, from, state) when is_binary(name) do
    cmd_for = fn cid ->
      base = %Pb.CompletePromiseCommandMessage{key: name, result_completion_id: cid}

      case completion do
        {:value, bytes} when is_binary(bytes) ->
          %{base | completion: {:completion_value, %Pb.Value{content: bytes}}}

        {:failure, code, message} when is_integer(code) and is_binary(message) ->
          %{base | completion: {:completion_failure, %Pb.Failure{code: code, message: message}}}
      end
    end

    case state.phase do
      :replaying ->
        with {:ok, {recorded, rest}} <-
               pop_recorded(state.recorded_commands, Pb.CompletePromiseCommandMessage) do
          state = state |> Map.put(:recorded_commands, rest) |> track_command(recorded) |> advance_phase()
          handle_promise_complete_result(state, recorded.result_completion_id, from)
        else
          {:error, exc} -> finalize_journal_mismatch(state, exc, from)
        end

      :processing ->
        cid = state.next_completion_id
        cmd = cmd_for.(cid)

        state =
          state
          |> Map.update!(:emitted, &[cmd | &1])
          |> Map.put(:next_completion_id, cid + 1)
          |> track_command(cmd)

        if state.cancelled? do
          {:reply, {:terminal_error, cancellation_error()}, state}
        else
          suspend(state, cid, from)
        end
    end
  end

  # `propose_run_and_suspend` is the run-flush primitive. The SDK
  # proposes the value/failure and immediately suspends on the run's
  # `result_completion_id` — Restate stores the proposal as a
  # `RunCompletionNotification`, then re-invokes us. On the next
  # invocation the journal contains both the RunCommand and its
  # completion, so the replay path returns `{:replay_value, _}` and
  # the handler proceeds to the next op.
  #
  # This costs one HTTP round-trip per `ctx.run` in REQUEST_RESPONSE
  # mode but is what the protocol requires — see `RunFlush` in the
  # conformance suite, which asserts side effects do NOT execute on
  # the final invocation (because every prior propose was journaled).
  def handle_call({:propose_run_and_suspend, cid, {:value, value}}, from, state) do
    propose = %Pb.ProposeRunCompletionMessage{
      result_completion_id: cid,
      result: {:value, encode_run_value(value)}
    }

    state = %{state | emitted: [propose | state.emitted]}
    suspend(state, cid, from)
  end

  def handle_call(
        {:propose_run_and_suspend, cid, {:failure, %Restate.TerminalError{} = exc}},
        from,
        state
      ) do
    metadata =
      Enum.map(exc.metadata || %{}, fn {k, v} ->
        %Pb.FailureMetadata{key: to_string(k), value: to_string(v)}
      end)

    propose = %Pb.ProposeRunCompletionMessage{
      result_completion_id: cid,
      result:
        {:failure, %Pb.Failure{code: exc.code, message: exc.message || "", metadata: metadata}}
    }

    state = %{state | emitted: [propose | state.emitted]}
    suspend(state, cid, from)
  end

  # --- Deferred-emit primitives for awaitable combinators ---
  #
  # `start_timer` and `start_call` emit the journal entry without
  # blocking. They return a handle (just the completion ids) which the
  # caller can later pass to `Restate.Awaitable.await/any/all`. The
  # existing :sleep / :call / :send handlers stay as the
  # blocking-convenience path used by `Context.sleep` etc.

  def handle_call({:start_timer, duration_ms}, from, state) do
    case state.phase do
      :replaying ->
        with {:ok, {recorded, rest}} <- pop_recorded(state.recorded_commands, Pb.SleepCommandMessage) do
          state = state |> Map.put(:recorded_commands, rest) |> track_command(recorded) |> advance_phase()
          {:reply, {:timer_handle, recorded.result_completion_id}, state}
        else
          {:error, exc} -> finalize_journal_mismatch(state, exc, from)
        end

      :processing ->
        cid = state.next_completion_id

        cmd = %Pb.SleepCommandMessage{
          wake_up_time: :os.system_time(:millisecond) + duration_ms,
          result_completion_id: cid
        }

        state =
          state
          |> Map.update!(:emitted, &[cmd | &1])
          |> Map.put(:next_completion_id, cid + 1)
          |> track_command(cmd)

        {:reply, {:timer_handle, cid}, state}
    end
  end

  def handle_call({:start_call, target}, from, state) do
    case state.phase do
      :replaying ->
        with {:ok, {recorded, rest}} <- pop_recorded(state.recorded_commands, Pb.CallCommandMessage) do
          state = state |> Map.put(:recorded_commands, rest) |> track_command(recorded) |> advance_phase()

          {:reply,
           {:call_handle, recorded.result_completion_id, recorded.invocation_id_notification_idx},
           state}
        else
          {:error, exc} -> finalize_journal_mismatch(state, exc, from)
        end

      :processing ->
        cid_invok = state.next_completion_id
        cid_result = cid_invok + 1

        cmd = %Pb.CallCommandMessage{
          service_name: target.service,
          handler_name: target.handler,
          parameter: target.parameter,
          key: target.key || "",
          idempotency_key: target.idempotency_key,
          invocation_id_notification_idx: cid_invok,
          result_completion_id: cid_result
        }

        state =
          state
          |> Map.update!(:emitted, &[cmd | &1])
          |> Map.put(:next_completion_id, cid_result + 1)
          |> track_command(cmd)

        {:reply, {:call_handle, cid_result, cid_invok}, state}
    end
  end

  def handle_call({:await_handles, mode, handles}, from, state)
      when mode in [:one, :any, :all] and is_list(handles) do
    do_await_handles(state, mode, handles, from)
  end

  # Surface the callee's invocation id for a deferred call_async handle.
  # Mirrors `handle_send_invocation_id/3` (the blocking `Context.send/5`
  # path) — same notification, same wire shape, just exposed via a
  # different SDK surface so callers who started the call with
  # `call_async` (no round-trip) can opt into the round-trip later when
  # they actually need the id (e.g. to cancel the callee out-of-band).
  #
  # Replay-safe: on the second call within the same handler, the
  # CallInvocationIdCompletionNotificationMessage is already in
  # state.notifications, so we return synchronously without re-suspending.
  # No new journal entry is emitted either way — this op rides the
  # CallCommand's existing invocation_id_notification_idx.
  def handle_call({:await_invocation_id, invok_cid}, from, state) when is_integer(invok_cid) do
    case Map.fetch(state.notifications, invok_cid) do
      {:ok, {:invocation_id, id}} when is_binary(id) ->
        {:reply, {:ok, id}, state}

      :error ->
        if state.cancelled? do
          # Notification not yet here, parent cancelled — raise 409.
          # We can't propagate cancel to the callee because we don't
          # know its id (that's literally what we're awaiting). The
          # callee will be torn down by the runtime when it observes
          # the parent's terminal failure.
          {:reply, {:terminal_error, cancellation_error()}, state}
        else
          suspend(state, invok_cid, from)
        end
    end
  end

  def handle_call({:sleep, duration_ms}, from, state) do
    case state.phase do
      :replaying ->
        with {:ok, {recorded, rest}} <- pop_recorded(state.recorded_commands, Pb.SleepCommandMessage) do
          state = state |> Map.put(:recorded_commands, rest) |> track_command(recorded) |> advance_phase()

          cond do
            Map.has_key?(state.notifications, recorded.result_completion_id) ->
              # Completion already in the replay journal — sleep returns now.
              {:reply, :ok, state}

            state.cancelled? ->
              # Sleep would block, but cancel preempts.
              {:reply, {:terminal_error, cancellation_error()}, state}

            true ->
              # Recorded sleep, completion not yet stored. Suspend on this id.
              suspend(state, recorded.result_completion_id, from)
          end
        else
          {:error, exc} -> finalize_journal_mismatch(state, exc, from)
        end

      :processing ->
        cid = state.next_completion_id

        cmd = %Pb.SleepCommandMessage{
          wake_up_time: :os.system_time(:millisecond) + duration_ms,
          result_completion_id: cid
        }

        state =
          state
          |> Map.update!(:emitted, &[cmd | &1])
          |> Map.put(:next_completion_id, cid + 1)
          |> track_command(cmd)

        if state.cancelled? do
          {:reply, {:terminal_error, cancellation_error()}, state}
        else
          # REQUEST_RESPONSE mode: no completion will arrive on this stream,
          # so we suspend immediately on the freshly-emitted sleep id.
          suspend(state, cid, from)
        end
    end
  end

  # The endpoint and the handler run concurrently — either could complete
  # first. We resolve the race by stashing whatever's missing.
  def handle_call(:await_response, _from, %{result_body: body, outcome: outcome} = state)
      when is_binary(body) do
    {:stop, :normal, {outcome, body}, state}
  end

  def handle_call(:await_response, from, state) do
    {:noreply, %{state | awaiting_response: from}}
  end

  @impl true
  def handle_info({:handler_result, {:ok, value}}, state) do
    output = %Pb.OutputCommandMessage{
      result: {:value, %Pb.Value{content: Restate.Serde.encode(value)}}
    }

    finalize(encode_response(state.emitted, [output, %Pb.EndMessage{}]), :value, state)
  end

  def handle_info({:handler_result, {:error, %Restate.TerminalError{} = e, _stack}}, state) do
    # Handler-raised business failure: lands in the journal as an
    # OutputCommandMessage{failure}, terminating the invocation
    # successfully (no runtime retry).
    metadata =
      Enum.map(e.metadata || %{}, fn {k, v} ->
        %Pb.FailureMetadata{key: to_string(k), value: to_string(v)}
      end)

    output = %Pb.OutputCommandMessage{
      result:
        {:failure,
         %Pb.Failure{code: e.code, message: e.message || "", metadata: metadata}}
    }

    finalize(
      encode_response(state.emitted, [output, %Pb.EndMessage{}]),
      :terminal_failure,
      state
    )
  end

  def handle_info({:handler_result, {:error, exception, stacktrace}}, state) do
    code =
      case exception do
        %Restate.ProtocolError{code: code} -> code
        _ -> 500
      end

    err =
      %Pb.ErrorMessage{
        code: code,
        message: Exception.message(exception),
        stacktrace: Exception.format_stacktrace(stacktrace)
      }
      |> with_related_command(state.current_command)

    # ErrorMessage on its own is a terminal frame (per V5 spec it
    # replaces EndMessage). State-mutating commands emitted before the
    # failure are still part of the journal and remain in
    # `state.emitted`. Codes:
    #   * 500   — generic handler failure; runtime retries.
    #   * 570   — JOURNAL_MISMATCH; runtime stops, surfaces to operator.
    #   * 571   — PROTOCOL_VIOLATION; same.
    finalize(encode_response(state.emitted, [err]), :error, state)
  end

  # --- helpers ---

  # Built-in cancel signal index. `BuiltInSignal.CANCEL = 1` in
  # protocol.proto:670. Java mirrors this as `CANCEL_SIGNAL_ID = 1` in
  # `StateMachineImpl.java`.
  @cancel_signal_id 1

  # Canonical exception raised when a suspending op is hit on a
  # cancelled invocation. 409 matches Restate's ABORTED convention
  # used by the runtime when it propagates cancellation.
  defp cancellation_error,
    do: %Restate.TerminalError{code: 409, message: "cancelled"}

  # Partition a post-Input replay journal into ordered commands, a
  # completion-id-keyed notifications map, a (user) signal-id-keyed
  # notifications map, and a cancellation flag. Entry-name commands like
  # OutputCommandMessage shouldn't appear in a replay (an Output ends the
  # invocation), but we tolerate them by keeping them in the command list.
  #
  # Signal id 1 is the built-in CANCEL signal — extracted into a flag
  # rather than the user signal map so awakeable lookups (which use ids
  # ≥ 17) never see it, and so the per-op cancel check is a single bool.
  defp partition_journal(frames) do
    Enum.reduce(frames, {[], %{}, %{}, false}, fn %Frame{message: msg}, {cmds, notes, sigs, cancelled?} ->
      cond do
        signal_notification?(msg) ->
          case signal_notification_id(msg) do
            @cancel_signal_id ->
              {cmds, notes, sigs, true}

            id when is_integer(id) ->
              {cmds, notes, Map.put(sigs, id, signal_notification_result(msg)), cancelled?}

            nil ->
              # Named-signal notification (signal_name oneof) — out of
              # v0.2 scope. Drop defensively rather than crashing.
              {cmds, notes, sigs, cancelled?}
          end

        notification?(msg) ->
          {cmds, Map.put(notes, msg.completion_id, notification_result(msg)), sigs, cancelled?}

        command?(msg) ->
          {[msg | cmds], notes, sigs, cancelled?}

        true ->
          # Suspension/Error/End/CommandAck shouldn't show up in a replay
          # journal; ignore defensively.
          {cmds, notes, sigs, cancelled?}
      end
    end)
    |> then(fn {cmds, notes, sigs, cancelled?} ->
      {Enum.reverse(cmds), notes, sigs, cancelled?}
    end)
  end

  # SignalNotificationMessage uses oneof id: completion_id | signal_id |
  # signal_name. We handle the indexed signal_id branch (used by
  # awakeables, signal_id 1 for CANCEL, and the user-allocated 17+
  # range). The signal_name branch is reserved for named external
  # signals — not exercised by the current conformance suite or any
  # shipped handler API; would land alongside a future
  # `Restate.Context.named_signal/2` if/when that's introduced.
  defp signal_notification?(%Pb.SignalNotificationMessage{}), do: true
  defp signal_notification?(_), do: false

  defp signal_notification_id(%Pb.SignalNotificationMessage{signal_id: {:idx, id}}), do: id
  defp signal_notification_id(_), do: nil

  defp signal_notification_result(%Pb.SignalNotificationMessage{result: result}), do: result
  defp signal_notification_result(_), do: :void

  defp notification?(%Pb.SleepCompletionNotificationMessage{}), do: true
  defp notification?(%Pb.GetLazyStateCompletionNotificationMessage{}), do: true
  defp notification?(%Pb.GetLazyStateKeysCompletionNotificationMessage{}), do: true
  defp notification?(%Pb.CallCompletionNotificationMessage{}), do: true
  defp notification?(%Pb.CallInvocationIdCompletionNotificationMessage{}), do: true
  defp notification?(%Pb.RunCompletionNotificationMessage{}), do: true
  defp notification?(%Pb.GetPromiseCompletionNotificationMessage{}), do: true
  defp notification?(%Pb.PeekPromiseCompletionNotificationMessage{}), do: true
  defp notification?(%Pb.CompletePromiseCompletionNotificationMessage{}), do: true
  defp notification?(_), do: false

  defp notification_result(%Pb.SleepCompletionNotificationMessage{void: void}), do: void || :void

  defp notification_result(%Pb.CallInvocationIdCompletionNotificationMessage{invocation_id: id}),
    do: {:invocation_id, id}

  defp notification_result(%Pb.GetLazyStateKeysCompletionNotificationMessage{
         state_keys: %Pb.StateKeys{keys: keys}
       }),
       do: {:state_keys, keys || []}

  defp notification_result(%Pb.GetLazyStateKeysCompletionNotificationMessage{}),
    do: {:state_keys, []}

  defp notification_result(%{result: result}), do: result
  defp notification_result(_), do: :void

  defp command?(%mod{}) do
    name = Atom.to_string(mod)
    String.ends_with?(name, "CommandMessage")
  end

  # Highest completion_id observed in the replay journal — across recorded
  # commands' `result_completion_id` and notifications' `completion_id`.
  # Returns 0 for an empty journal so callers can use `+1` to seed a
  # one-based counter.
  #
  # Signal IDs are a separate namespace: slots 1–16 are reserved for
  # built-in signals (CANCEL = 1; see protocol.proto:670) and user
  # allocations start at 17 to match `Journal.signalIndex` in
  # `sdk-java/.../statemachine/Journal.java`. Completion IDs share
  # the 1+ range with signals only nominally — they never collide
  # because they live on different oneof branches of NotificationTemplate.
  defp max_completion_id_seen(frames) do
    frames
    |> Enum.flat_map(&extract_completion_ids/1)
    |> Enum.max(fn -> 0 end)
  end

  defp extract_completion_ids(%Frame{message: %Pb.SignalNotificationMessage{}}), do: []

  defp extract_completion_ids(%Frame{message: %{result_completion_id: id}}) when is_integer(id),
    do: [id]

  defp extract_completion_ids(%Frame{message: %{completion_id: id}}) when is_integer(id), do: [id]
  defp extract_completion_ids(_), do: []

  # Pop the next recorded command, asserting its protobuf module matches
  # `expected_mod`. Returns `{:ok, {head, rest}}` on match, `{:error,
  # %Restate.ProtocolError{}}` on type mismatch or empty journal — caller
  # routes the error through `finalize_journal_mismatch/3` so the runtime
  # gets ErrorMessage{code: 570} rather than the GenServer crashing.
  defp pop_recorded([%expected_mod{} = head | rest], expected_mod), do: {:ok, {head, rest}}

  defp pop_recorded([%mod{} | _], expected_mod) do
    {:error,
     %Restate.ProtocolError{
       message:
         "journal mismatch: expected #{inspect(expected_mod)}, " <>
           "next recorded entry is #{inspect(mod)}",
       code: Restate.ProtocolError.journal_mismatch()
     }}
  end

  defp pop_recorded([], expected_mod) do
    {:error,
     %Restate.ProtocolError{
       message:
         "journal mismatch: expected #{inspect(expected_mod)}, journal exhausted",
       code: Restate.ProtocolError.journal_mismatch()
     }}
  end

  # ctx.call replay path — once the recorded CallCommand is popped,
  # check whether the target's result is already in the notifications
  # map. Replies to the caller with a tagged tuple;
  # `Restate.Context.call` raises on `:terminal_error` so user code
  # sees an exception, not a tuple.
  #
  # Cancel raises at this await site only when the call result is NOT
  # in the journal — i.e. only when the call is the "current blocking
  # op" the cancel should interrupt. If the result is already there,
  # we return it; cancel will fire at the next still-blocking op (or
  # the handler runs to completion). When we do raise, we first
  # propagate the cancel to the callee — Restate's runtime does not
  # auto-cascade `cancelInvocation` through the call tree, so without
  # this the BlockingService would keep running until its own
  # blocking op completed naturally. Verified against `restate-server`
  # 1.6.3 by inspecting NotifySignal events in the runtime log.
  defp handle_call_result(state, %Pb.CallCommandMessage{} = recorded, from) do
    case Map.fetch(state.notifications, recorded.result_completion_id) do
      {:ok, {:value, %Pb.Value{content: bytes}}} ->
        {:reply, {:ok, decode_response(bytes)}, state}

      {:ok, {:failure, %Pb.Failure{code: code, message: message, metadata: meta}}} ->
        metadata_map = decode_failure_metadata(meta)
        exc = %Restate.TerminalError{code: code, message: message, metadata: metadata_map}
        {:reply, {:terminal_error, exc}, state}

      :error ->
        if state.cancelled? do
          state = propagate_cancel_to_callee(state, recorded.invocation_id_notification_idx)
          {:reply, {:terminal_error, cancellation_error()}, state}
        else
          # Result not in journal yet — suspend on the result completion id.
          suspend(state, recorded.result_completion_id, from)
        end
    end
  end

  # Look up the callee's invocation_id from the
  # CallInvocationIdCompletionNotification (if the runtime has
  # delivered it) and emit a SendSignal(idx=1, void) targeting it.
  # Goes into `state.emitted` so the cascade ships in the same wire
  # response as the OutputCommandMessage{failure}.
  defp propagate_cancel_to_callee(state, invocation_id_notification_idx) do
    case Map.get(state.notifications, invocation_id_notification_idx) do
      {:invocation_id, target_id} when is_binary(target_id) and byte_size(target_id) > 0 ->
        cmd = %Pb.SendSignalCommandMessage{
          target_invocation_id: target_id,
          signal_id: {:idx, @cancel_signal_id},
          result: {:void, %Pb.Void{}}
        }

        %{state | emitted: [cmd | state.emitted]}

      _ ->
        # Runtime hasn't reported the callee's id yet — nothing to
        # cancel. The callee is either not started or will start on a
        # journal we never see again.
        state
    end
  end

  # --- Lazy state ---
  #
  # `partial_state?` is true when the runtime did not bundle every
  # state value into `StartMessage.state_map` (typically because the
  # bundle would exceed a size threshold). Missing keys must be
  # fetched via `GetLazyStateCommandMessage`; the full key set via
  # `GetLazyStateKeysCommandMessage`.
  #
  # The cache lives in `state.state_map`: bytes for present values,
  # `nil` for keys we know are absent (lazily fetched + Void, or
  # explicitly cleared in this invocation), missing-from-map for
  # keys we haven't probed yet.

  defp do_lazy_get_state(state, key, from) do
    case state.phase do
      :replaying ->
        with {:ok, {recorded, rest}} <-
               pop_recorded(state.recorded_commands, Pb.GetLazyStateCommandMessage) do
          if recorded.key == key do
            state = state |> Map.put(:recorded_commands, rest) |> track_command(recorded) |> advance_phase()
            handle_lazy_get_state_result(state, key, recorded.result_completion_id, from)
          else
            finalize_journal_mismatch(
              state,
              %Restate.ProtocolError{
                message:
                  "GetLazyState key mismatch: handler asked for " <>
                    inspect(key) <> ", journal has " <> inspect(recorded.key),
                code: Restate.ProtocolError.journal_mismatch()
              },
              from
            )
          end
        else
          {:error, exc} -> finalize_journal_mismatch(state, exc, from)
        end

      :processing ->
        cid = state.next_completion_id
        cmd = %Pb.GetLazyStateCommandMessage{key: key, result_completion_id: cid}

        state =
          state
          |> Map.update!(:emitted, &[cmd | &1])
          |> Map.put(:next_completion_id, cid + 1)
          |> track_command(cmd)

        if state.cancelled? do
          {:reply, {:terminal_error, cancellation_error()}, state}
        else
          suspend(state, cid, from)
        end
    end
  end

  defp handle_lazy_get_state_result(state, key, result_completion_id, from) do
    case Map.fetch(state.notifications, result_completion_id) do
      {:ok, {:value, %Pb.Value{content: bytes}}} ->
        state = %{state | state_map: Map.put(state.state_map, key, bytes)}
        {:reply, bytes, state}

      {:ok, {:void, _}} ->
        state = %{state | state_map: Map.put(state.state_map, key, nil)}
        {:reply, nil, state}

      :error ->
        if state.cancelled? do
          {:reply, {:terminal_error, cancellation_error()}, state}
        else
          suspend(state, result_completion_id, from)
        end
    end
  end

  defp do_lazy_state_keys(state, from) do
    case state.phase do
      :replaying ->
        with {:ok, {recorded, rest}} <-
               pop_recorded(state.recorded_commands, Pb.GetLazyStateKeysCommandMessage) do
          state = state |> Map.put(:recorded_commands, rest) |> track_command(recorded) |> advance_phase()
          handle_lazy_state_keys_result(state, recorded.result_completion_id, from)
        else
          {:error, exc} -> finalize_journal_mismatch(state, exc, from)
        end

      :processing ->
        cid = state.next_completion_id
        cmd = %Pb.GetLazyStateKeysCommandMessage{result_completion_id: cid}

        state =
          state
          |> Map.update!(:emitted, &[cmd | &1])
          |> Map.put(:next_completion_id, cid + 1)
          |> track_command(cmd)

        if state.cancelled? do
          {:reply, {:terminal_error, cancellation_error()}, state}
        else
          suspend(state, cid, from)
        end
    end
  end

  defp handle_lazy_state_keys_result(state, result_completion_id, from) do
    case Map.fetch(state.notifications, result_completion_id) do
      {:ok, {:state_keys, keys}} ->
        state = %{state | state_keys_cache: keys}
        {:reply, current_state_keys(state), state}

      :error ->
        if state.cancelled? do
          {:reply, {:terminal_error, cancellation_error()}, state}
        else
          suspend(state, result_completion_id, from)
        end
    end
  end

  # Runtime-known keys (cached from a prior GetLazyStateKeys, or empty
  # when state is eager) merged with the local invocation's set/clear
  # deltas. Cleared keys are stored as `{key, nil}` in state_map.
  defp current_state_keys(state) do
    cached = MapSet.new(state.state_keys_cache || [])

    Enum.reduce(state.state_map, cached, fn
      {k, nil}, acc -> MapSet.delete(acc, k)
      {k, _bytes}, acc -> MapSet.put(acc, k)
    end)
    |> MapSet.to_list()
  end

  # promise_get: same shape as a Value-or-Failure-only completable
  # (no Void variant per the protocol — GetPromise blocks until
  # actually resolved). Cancel preempts only when the journal has
  # no completion for this op yet.
  defp handle_promise_value_result(state, result_completion_id, from) do
    case Map.fetch(state.notifications, result_completion_id) do
      {:ok, {:value, %Pb.Value{content: bytes}}} ->
        {:reply, {:ok, decode_response(bytes)}, state}

      {:ok, {:failure, %Pb.Failure{code: code, message: message, metadata: meta}}} ->
        exc = %Restate.TerminalError{
          code: code,
          message: message,
          metadata: decode_failure_metadata(meta)
        }

        {:reply, {:terminal_error, exc}, state}

      :error ->
        if state.cancelled? do
          {:reply, {:terminal_error, cancellation_error()}, state}
        else
          suspend(state, result_completion_id, from)
        end
    end
  end

  # promise_peek: Void completion means "promise still unresolved" —
  # surface as `:pending` to the caller, who decides whether to wait
  # or branch.
  defp handle_promise_peek_result(state, result_completion_id, from) do
    case Map.fetch(state.notifications, result_completion_id) do
      {:ok, {:void, _}} ->
        {:reply, :pending, state}

      {:ok, {:value, %Pb.Value{content: bytes}}} ->
        {:reply, {:ok, decode_response(bytes)}, state}

      {:ok, {:failure, %Pb.Failure{code: code, message: message, metadata: meta}}} ->
        exc = %Restate.TerminalError{
          code: code,
          message: message,
          metadata: decode_failure_metadata(meta)
        }

        {:reply, {:terminal_error, exc}, state}

      :error ->
        if state.cancelled? do
          {:reply, {:terminal_error, cancellation_error()}, state}
        else
          suspend(state, result_completion_id, from)
        end
    end
  end

  # promise_complete: the runtime acks the resolution with Void on
  # success, Failure if e.g. the promise was already rejected and
  # can't be resolved. Surface success as :ok, failure as
  # {:terminal_error, exc}.
  defp handle_promise_complete_result(state, result_completion_id, from) do
    case Map.fetch(state.notifications, result_completion_id) do
      {:ok, {:void, _}} ->
        {:reply, :ok, state}

      {:ok, {:failure, %Pb.Failure{code: code, message: message, metadata: meta}}} ->
        exc = %Restate.TerminalError{
          code: code,
          message: message,
          metadata: decode_failure_metadata(meta)
        }

        {:reply, {:terminal_error, exc}, state}

      :error ->
        if state.cancelled? do
          {:reply, {:terminal_error, cancellation_error()}, state}
        else
          suspend(state, result_completion_id, from)
        end
    end
  end

  # ctx.send replay/processing — we wait on the invocation_id notification
  # so callers can use the id of the spawned invocation.
  defp handle_send_invocation_id(state, invocation_id_completion_id, from) do
    cond do
      state.cancelled? ->
        {:reply, {:terminal_error, cancellation_error()}, state}

      true ->
        case Map.fetch(state.notifications, invocation_id_completion_id) do
          {:ok, {:invocation_id, id}} when is_binary(id) ->
            {:reply, {:ok, id}, state}

          :error ->
            suspend(state, invocation_id_completion_id, from)
        end
    end
  end

  defp decode_response(bytes) when is_binary(bytes), do: Restate.Serde.decode(bytes)

  # Encode the run's return value via the configured `Restate.Serde`
  # (default JSON) so it round-trips through `decode_response/1` on
  # replay. The `{:raw, bytes}` form is the explicit opt-out for
  # callers who already hold pre-encoded wire bytes — bypasses the
  # serde entirely (mirrors the same pattern in
  # `Restate.Context.encode_parameter/1` and `Proxy.result_to_binary/1`).
  defp encode_run_value({:raw, bytes}) when is_binary(bytes), do: bytes
  defp encode_run_value(term), do: Restate.Serde.encode(term)

  # Awakeable id encoding for V5 / signal-based awakeables.
  #
  #   "sign_1" + base64url(StartMessage.id ++ <<signal_id::32-big>>)
  #
  # Restate's runtime distinguishes two awakeable id formats:
  #   * "prom_1..." → AwakeableIdentifier → routes the completion as a
  #     completion-id-keyed notification (V1–V4 model). Using this on a
  #     V5 SDK produces "no command in journal for completion index N"
  #     errors at the runtime.
  #   * "sign_1..." → ExternalSignalIdentifier → routes via
  #     OutboxMessage::NotifySignal → SignalNotificationMessage on the
  #     target invocation's journal. This is what V5 wants.
  #
  # See restate-server's
  # `crates/worker/.../complete_awakeable_command.rs::apply` and
  # `crates/types/src/id_util.rs::IdResourceType` for the routing
  # decision and the prefix mapping.
  #
  # The bytes layout is the same for both — invocation_id bytes
  # followed by a 32-bit big-endian index — so the only thing the
  # runtime keys off is the prefix.
  defp encode_awakeable_id(start_id, signal_id) when is_binary(start_id) do
    encoded = Base.url_encode64(start_id <> <<signal_id::32-big>>, padding: false)
    "sign_1" <> encoded
  end

  defp build_complete_awakeable(awakeable_id, {:value, bytes}) when is_binary(bytes) do
    %Pb.CompleteAwakeableCommandMessage{
      awakeable_id: awakeable_id,
      result: {:value, %Pb.Value{content: bytes}}
    }
  end

  defp build_complete_awakeable(awakeable_id, {:failure, code, message}) do
    %Pb.CompleteAwakeableCommandMessage{
      awakeable_id: awakeable_id,
      result: {:failure, %Pb.Failure{code: code, message: message}}
    }
  end

  # --- Combinator (Awaitable.any / .all / await) implementation ---

  # Resolve a single handle against the current state. Returns
  # `:pending` if its completion isn't in the journal yet. Used by both
  # the single-handle await and the combinators.
  defp lookup_handle(state, {:timer_handle, cid}) do
    case Map.fetch(state.notifications, cid) do
      :error -> :pending
      # Sleep completion is :void (no payload) — sleep itself returns :ok.
      {:ok, _} -> {:ok, :ok}
    end
  end

  defp lookup_handle(state, {:call_handle, result_cid, _invok_cid}) do
    case Map.fetch(state.notifications, result_cid) do
      :error ->
        :pending

      {:ok, {:value, %Pb.Value{content: bytes}}} ->
        {:ok, decode_response(bytes)}

      {:ok, {:failure, %Pb.Failure{code: code, message: message, metadata: meta}}} ->
        {:terminal_error,
         %Restate.TerminalError{
           code: code,
           message: message,
           metadata: decode_failure_metadata(meta)
         }}
    end
  end

  defp lookup_handle(state, {:awakeable_handle, signal_id}) do
    case Map.fetch(state.signal_notifications, signal_id) do
      :error ->
        :pending

      {:ok, {:value, %Pb.Value{content: bytes}}} ->
        {:ok, decode_response(bytes)}

      {:ok, {:failure, %Pb.Failure{code: code, message: message, metadata: meta}}} ->
        {:terminal_error,
         %Restate.TerminalError{
           code: code,
           message: message,
           metadata: decode_failure_metadata(meta)
         }}

      {:ok, _} ->
        # Void / other shapes — completed without payload.
        {:ok, nil}
    end
  end

  # Synthetic handle for already-resolved values (e.g. a Run that
  # threw inline before being composed). Lets handler code uniformly
  # treat sync-resolved and journal-completable items in
  # Awaitable.any/all.
  defp lookup_handle(_state, {:resolved, {:ok, value}}), do: {:ok, value}
  defp lookup_handle(_state, {:resolved, {:terminal_error, %Restate.TerminalError{} = exc}}),
    do: {:terminal_error, exc}

  # Reply-shape: list of `{:ok, value}` / `{:terminal_error, exc}` /
  # `:pending` per handle.
  defp do_await_handles(state, mode, handles, from) do
    results = Enum.map(handles, &lookup_handle(state, &1))

    case dispatch_handles(mode, handles, results, state) do
      {:ready, reply} ->
        {:reply, reply, state}

      {:suspend_or_cancel, missing_handles} ->
        if state.cancelled? do
          state = propagate_cancel_to_outstanding(state, missing_handles)
          {:reply, {:terminal_error, cancellation_error()}, state}
        else
          suspend_for_handles(state, missing_handles, from)
        end
    end
  end

  # Decide how to reply based on combinator mode and current per-handle
  # results. Returns either {:ready, reply} (all info available) or
  # {:suspend_or_cancel, [missing_handles]}.
  defp dispatch_handles(:one, [handle], [:pending], _state),
    do: {:suspend_or_cancel, [handle]}

  defp dispatch_handles(:one, _handles, [{:ok, value}], _state),
    do: {:ready, {:ok, value}}

  defp dispatch_handles(:one, _handles, [{:terminal_error, exc}], _state),
    do: {:ready, {:terminal_error, exc}}

  defp dispatch_handles(:any, handles, results, _state) do
    case Enum.find_index(results, fn r -> r != :pending end) do
      nil ->
        {:suspend_or_cancel, handles}

      idx ->
        case Enum.at(results, idx) do
          {:ok, value} -> {:ready, {:ok, {:any, idx, value}}}
          {:terminal_error, exc} -> {:ready, {:any_terminal_error, idx, exc}}
        end
    end
  end

  defp dispatch_handles(:all, handles, results, _state) do
    case Enum.find_index(results, fn r -> match?({:terminal_error, _}, r) end) do
      idx when is_integer(idx) ->
        # First failure short-circuits — match Java's Promise.all semantics.
        {:terminal_error, exc} = Enum.at(results, idx)
        {:ready, {:terminal_error, exc}}

      nil ->
        case Enum.find_index(results, fn r -> r == :pending end) do
          nil ->
            values = Enum.map(results, fn {:ok, v} -> v end)
            {:ready, {:ok, values}}

          _ ->
            missing =
              handles
              |> Enum.zip(results)
              |> Enum.filter(fn {_, r} -> r == :pending end)
              |> Enum.map(fn {h, _} -> h end)

            {:suspend_or_cancel, missing}
        end
    end
  end

  # Suspend on the union of completion ids and signal ids for the
  # missing handles, plus signal_id 1 (CANCEL) so cancel always wins.
  defp suspend_for_handles(state, handles, _from) do
    {completions, signals} =
      Enum.reduce(handles, {[], [@cancel_signal_id]}, fn
        {:timer_handle, cid}, {comps, sigs} -> {[cid | comps], sigs}
        {:call_handle, result_cid, _invok_cid}, {comps, sigs} -> {[result_cid | comps], sigs}
        {:awakeable_handle, sid}, {comps, sigs} -> {comps, [sid | sigs]}
        {:resolved, _}, acc -> acc
      end)

    suspension = %Pb.SuspensionMessage{
      waiting_completions: completions |> Enum.uniq() |> Enum.sort(),
      waiting_signals: signals |> Enum.uniq() |> Enum.sort()
    }

    body = encode_response(state.emitted, [suspension])
    finalize(body, :suspended, state)
  end

  # Propagate cancel to any in-flight call handles. Sleep + awakeable +
  # resolved have nothing to propagate to.
  defp propagate_cancel_to_outstanding(state, handles) do
    Enum.reduce(handles, state, fn
      {:call_handle, _result_cid, invok_cid}, st ->
        propagate_cancel_to_callee(st, invok_cid)

      _, st ->
        st
    end)
  end

  # Like suspend/3 but uses waiting_signals instead of waiting_completions.
  # Awakeables are signal-id-based per the V5 spec; the runtime resumes
  # the invocation when any of the waiting signals fires. We also list
  # signal_id 1 so cancel can interrupt an awakeable wait — see
  # `suspend/3` for the rationale.
  defp suspend_signal(state, signal_id, _from) do
    suspension = %Pb.SuspensionMessage{
      waiting_signals: Enum.uniq([signal_id, @cancel_signal_id])
    }

    body = encode_response(state.emitted, [suspension])
    finalize(body, :suspended, state)
  end

  defp decode_failure_metadata(nil), do: %{}

  defp decode_failure_metadata(metadata) when is_list(metadata) do
    Enum.into(metadata, %{}, fn %Pb.FailureMetadata{key: k, value: v} -> {k, v} end)
  end

  # Build an ErrorMessage{code: 570/571} from a Restate.ProtocolError, route
  # it through finalize. The handler's GenServer.call goes un-replied; when
  # the Invocation exits :normal, the handler's call detects DOWN and the
  # handler exits — same close-out shape as suspension.
  defp finalize_journal_mismatch(state, %Restate.ProtocolError{} = exc, _from) do
    :telemetry.execute(
      [:restate, :invocation, :journal_mismatch],
      %{monotonic_time: System.monotonic_time()},
      Map.merge(state.dispatch_meta, %{
        code: exc.code,
        message: exc.message,
        command_index: state.current_command.index
      })
    )

    err =
      %Pb.ErrorMessage{code: exc.code, message: exc.message}
      |> with_related_command(state.current_command)

    finalize(encode_response(state.emitted, [err]), :journal_mismatch, state)
  end

  defp advance_phase(%{phase: :replaying, recorded_commands: []} = state) do
    :telemetry.execute(
      [:restate, :invocation, :replay_complete],
      %{
        monotonic_time: System.monotonic_time(),
        replayed_commands: state.replay_journal_size
      },
      state.dispatch_meta
    )

    %{state | phase: :processing, replay_phase_completed?: true}
  end

  defp advance_phase(state), do: state

  # Bump current_command tracking after a command is consumed (replay) or
  # emitted (processing). Populates ErrorMessage.related_command_* on
  # subsequent failures.
  defp track_command(state, %mod{} = cmd) do
    name =
      case Map.get(cmd, :name, "") do
        "" -> nil
        name when is_binary(name) -> name
        _ -> nil
      end

    %{
      state
      | current_command: %{
          index: state.current_command.index + 1,
          name: name,
          type: Restate.Protocol.Messages.type_for_module(mod)
        }
    }
  end

  # Populate ErrorMessage.related_command_* fields from tracked
  # current_command. Index < 0 means no command has been processed yet
  # (e.g. handler raised before any context call) — leave fields unset.
  defp with_related_command(%Pb.ErrorMessage{} = err, %{index: index, name: name, type: type})
       when index >= 0 do
    err = %{err | related_command_index: index}
    err = if name, do: %{err | related_command_name: name}, else: err
    err = if type, do: %{err | related_command_type: type}, else: err
    err
  end

  defp with_related_command(err, _), do: err

  # Suspend on `completion_id`. The handler call (`from`) is left
  # un-replied-to: when we exit, the linked handler process dies and the
  # caller never receives a reply (which is what we want — handler
  # execution is over for this invocation).
  #
  # Every suspension also lists signal_id 1 (built-in CANCEL) in
  # `waiting_signals`. Without it, Restate would only re-invoke when
  # the user-level completion fires, so a cancel arriving while we're
  # blocked on a long sleep / outstanding call would never wake us
  # up — the SDK-side cancel-handling code is correct, but it never
  # gets a chance to run. Listing 1 unconditionally is what every other
  # SDK does (verified against `sdk-java`'s suspension paths) and
  # tracks the V5 spec note in `protocol.proto:670`.
  defp suspend(state, completion_id, _from) do
    suspension = %Pb.SuspensionMessage{
      waiting_completions: [completion_id],
      waiting_signals: [@cancel_signal_id]
    }

    body = encode_response(state.emitted, [suspension])
    finalize(body, :suspended, state)
  end

  # `outcome` is one of `:value | :terminal_failure | :error |
  # :suspended | :journal_mismatch` and is returned alongside the
  # body from `await_response/2`.
  defp finalize(body, outcome, %{awaiting_response: nil} = state) do
    {:noreply, %{state | result_body: body, outcome: outcome}}
  end

  defp finalize(body, outcome, %{awaiting_response: from} = state) do
    GenServer.reply(from, {outcome, body})
    {:stop, :normal, %{state | outcome: outcome}}
  end

  defp encode_response(emitted_reversed, trailing) do
    (Enum.reverse(emitted_reversed) ++ trailing)
    |> Enum.map_join(<<>>, &Framer.encode/1)
  end
end
