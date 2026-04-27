defmodule Restate.Server.Invocation do
  @moduledoc """
  One process per HTTP invocation. Implements the V5 state machine:
  `:replaying` while there are recorded journal commands to consume,
  `:processing` once the handler has caught up to the head of the journal.

  ## Lifecycle

      Endpoint → Invocation.start_link({start, input, replay_journal, mfa})
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
  """
  @spec start_link(
          {Pb.StartMessage.t(), term(), [Frame.t()], {module(), atom(), arity()}}
        ) :: GenServer.on_start()
  def start_link({%Pb.StartMessage{}, _input, replay_journal, _mfa} = arg)
      when is_list(replay_journal) do
    GenServer.start_link(__MODULE__, arg)
  end

  @doc """
  Block until the handler completes (or suspends, or raises) and return
  the framed response body. Stops the invocation process on return.
  """
  @spec await_response(pid(), timeout()) :: binary()
  def await_response(pid, timeout \\ 30_000) do
    GenServer.call(pid, :await_response, timeout)
  end

  # --- GenServer ---

  @impl true
  def init({%Pb.StartMessage{state_map: state_entries, key: object_key}, input, replay_journal, mfa}) do
    state_map =
      for %Pb.StartMessage.StateEntry{key: k, value: v} <- state_entries, into: %{} do
        {k, v}
      end

    {recorded_commands, notifications} = partition_journal(replay_journal)
    initial_completion_id = max_completion_id_seen(replay_journal) + 1

    # Register with the DrainCoordinator so SIGTERM-triggered drain can
    # wait for us to finish before stopping the BEAM. No-op when the
    # coordinator isn't running (e.g. in test envs that don't boot it).
    Restate.Server.DrainCoordinator.register(self())

    parent = self()

    handler_pid =
      spawn_link(fn ->
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
       state_map: state_map,
       recorded_commands: recorded_commands,
       notifications: notifications,
       next_completion_id: initial_completion_id,
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
  def handle_call({:get_state, key}, _from, state) do
    {:reply, Map.get(state.state_map, key), state}
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

  def handle_call({:clear_state, key}, from, state) do
    cmd = %Pb.ClearStateCommandMessage{key: key}
    state = %{state | state_map: Map.delete(state.state_map, key)}

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
          handle_call_result(state, recorded.result_completion_id, from)
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

        # REQUEST_RESPONSE: the result notification arrives on a
        # subsequent invocation, so we suspend on cid_result.
        suspend(state, cid_result, from)
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

        # We block on the invocation_id notification so callers can
        # use the spawned invocation's id (e.g. Proxy.oneWayCall
        # returns it). REQUEST_RESPONSE mode: arrives on next replay.
        suspend(state, cid_invok, from)
    end
  end

  def handle_call({:sleep, duration_ms}, from, state) do
    case state.phase do
      :replaying ->
        with {:ok, {recorded, rest}} <- pop_recorded(state.recorded_commands, Pb.SleepCommandMessage) do
          state = state |> Map.put(:recorded_commands, rest) |> track_command(recorded) |> advance_phase()

          case Map.fetch(state.notifications, recorded.result_completion_id) do
            {:ok, _} ->
              # Completion already in the replay journal — sleep returns now.
              {:reply, :ok, state}

            :error ->
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

        # REQUEST_RESPONSE mode: no completion will arrive on this stream,
        # so we suspend immediately on the freshly-emitted sleep id.
        suspend(state, cid, from)
    end
  end

  # The endpoint and the handler run concurrently — either could complete
  # first. We resolve the race by stashing whatever's missing.
  def handle_call(:await_response, _from, %{result_body: body} = state) when is_binary(body) do
    {:stop, :normal, body, state}
  end

  def handle_call(:await_response, from, state) do
    {:noreply, %{state | awaiting_response: from}}
  end

  @impl true
  def handle_info({:handler_result, {:ok, value}}, state) do
    output = %Pb.OutputCommandMessage{
      result: {:value, %Pb.Value{content: Jason.encode!(value)}}
    }

    finalize(encode_response(state.emitted, [output, %Pb.EndMessage{}]), state)
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

    finalize(encode_response(state.emitted, [output, %Pb.EndMessage{}]), state)
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
    finalize(encode_response(state.emitted, [err]), state)
  end

  # --- helpers ---

  # Partition a post-Input replay journal into ordered commands and a
  # completion-id-keyed notifications map. Entry-name commands like
  # OutputCommandMessage shouldn't appear in a replay (an Output ends the
  # invocation), but we tolerate them by keeping them in the command list.
  defp partition_journal(frames) do
    Enum.reduce(frames, {[], %{}}, fn %Frame{message: msg}, {cmds, notes} ->
      cond do
        notification?(msg) ->
          {cmds, Map.put(notes, msg.completion_id, notification_result(msg))}

        command?(msg) ->
          {[msg | cmds], notes}

        true ->
          # Suspension/Error/End/CommandAck shouldn't show up in a replay
          # journal; ignore defensively.
          {cmds, notes}
      end
    end)
    |> then(fn {cmds, notes} -> {Enum.reverse(cmds), notes} end)
  end

  defp notification?(%Pb.SleepCompletionNotificationMessage{}), do: true
  defp notification?(%Pb.GetLazyStateCompletionNotificationMessage{}), do: true
  defp notification?(%Pb.CallCompletionNotificationMessage{}), do: true
  defp notification?(%Pb.CallInvocationIdCompletionNotificationMessage{}), do: true
  defp notification?(%Pb.RunCompletionNotificationMessage{}), do: true
  defp notification?(_), do: false

  defp notification_result(%Pb.SleepCompletionNotificationMessage{void: void}), do: void || :void

  defp notification_result(%Pb.CallInvocationIdCompletionNotificationMessage{invocation_id: id}),
    do: {:invocation_id, id}

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
  # Note for v0.2: signal IDs reserve slots 1–16 per Java's
  # `Journal.signalIndex = 17` (sdk-java/.../statemachine/Journal.java:27).
  # When SendSignalCommandMessage support lands, signal-id allocation
  # must start at 17, not at 1; completion-ids share the slot 1+ range
  # because they're a different namespace.
  defp max_completion_id_seen(frames) do
    frames
    |> Enum.flat_map(&extract_completion_ids/1)
    |> Enum.max(fn -> 0 end)
  end

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

  # ctx.call replay/processing — once we've located the recorded
  # command (or emitted a fresh one), check whether the target's
  # result is already in the notifications map. Replies to the
  # caller with a tagged tuple; `Restate.Context.call` raises on
  # `:terminal_error` so user code sees an exception, not a tuple.
  defp handle_call_result(state, result_completion_id, from) do
    case Map.fetch(state.notifications, result_completion_id) do
      {:ok, {:value, %Pb.Value{content: bytes}}} ->
        {:reply, {:ok, decode_response(bytes)}, state}

      {:ok, {:failure, %Pb.Failure{code: code, message: message, metadata: meta}}} ->
        metadata_map = decode_failure_metadata(meta)
        exc = %Restate.TerminalError{code: code, message: message, metadata: metadata_map}
        {:reply, {:terminal_error, exc}, state}

      :error ->
        # Result not in journal yet — suspend on the result completion id.
        suspend(state, result_completion_id, from)
    end
  end

  # ctx.send replay/processing — we wait on the invocation_id notification
  # so callers can use the id of the spawned invocation.
  defp handle_send_invocation_id(state, invocation_id_completion_id, from) do
    case Map.fetch(state.notifications, invocation_id_completion_id) do
      {:ok, {:invocation_id, id}} when is_binary(id) ->
        {:reply, id, state}

      :error ->
        suspend(state, invocation_id_completion_id, from)
    end
  end

  defp decode_response(""), do: nil
  defp decode_response(bytes) when is_binary(bytes), do: Jason.decode!(bytes)

  defp decode_failure_metadata(nil), do: %{}

  defp decode_failure_metadata(metadata) when is_list(metadata) do
    Enum.into(metadata, %{}, fn %Pb.FailureMetadata{key: k, value: v} -> {k, v} end)
  end

  # Build an ErrorMessage{code: 570/571} from a Restate.ProtocolError, route
  # it through finalize. The handler's GenServer.call goes un-replied; when
  # the Invocation exits :normal, the handler's call detects DOWN and the
  # handler exits — same close-out shape as suspension.
  defp finalize_journal_mismatch(state, %Restate.ProtocolError{} = exc, _from) do
    err =
      %Pb.ErrorMessage{code: exc.code, message: exc.message}
      |> with_related_command(state.current_command)

    finalize(encode_response(state.emitted, [err]), state)
  end

  defp advance_phase(%{recorded_commands: []} = state), do: %{state | phase: :processing}
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
  defp suspend(state, completion_id, _from) do
    suspension = %Pb.SuspensionMessage{waiting_completions: [completion_id]}
    body = encode_response(state.emitted, [suspension])
    finalize(body, state)
  end

  defp finalize(body, %{awaiting_response: nil} = state) do
    {:noreply, %{state | result_body: body}}
  end

  defp finalize(body, %{awaiting_response: from} = state) do
    GenServer.reply(from, body)
    {:stop, :normal, state}
  end

  defp encode_response(emitted_reversed, trailing) do
    (Enum.reverse(emitted_reversed) ++ trailing)
    |> Enum.map_join(<<>>, &Framer.encode/1)
  end
end
