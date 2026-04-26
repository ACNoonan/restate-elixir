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
  def init({%Pb.StartMessage{state_map: state_entries}, input, replay_journal, mfa}) do
    state_map =
      for %Pb.StartMessage.StateEntry{key: k, value: v} <- state_entries, into: %{} do
        {k, v}
      end

    {recorded_commands, notifications} = partition_journal(replay_journal)

    parent = self()

    handler_pid =
      spawn_link(fn ->
        ctx = %Restate.Context{pid: parent}
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
       next_completion_id: starting_completion_id(replay_journal),
       emitted: [],
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
  def handle_call({:set_state, key, value_bytes}, _from, state) do
    cmd = %Pb.SetStateCommandMessage{key: key, value: %Pb.Value{content: value_bytes}}
    state = %{state | state_map: Map.put(state.state_map, key, value_bytes)}

    case state.phase do
      :replaying ->
        # In replay we do NOT re-emit; we only consume the next recorded
        # command and validate it's a SetStateCommandMessage.
        {_, rest} = pop_recorded!(state.recorded_commands, Pb.SetStateCommandMessage)
        {:reply, :ok, advance_phase(%{state | recorded_commands: rest})}

      :processing ->
        {:reply, :ok, %{state | emitted: [cmd | state.emitted]}}
    end
  end

  def handle_call({:sleep, duration_ms}, from, state) do
    case state.phase do
      :replaying ->
        {recorded, rest} = pop_recorded!(state.recorded_commands, Pb.SleepCommandMessage)
        state = advance_phase(%{state | recorded_commands: rest})

        case Map.fetch(state.notifications, recorded.result_completion_id) do
          {:ok, _} ->
            # Completion already in the replay journal — sleep returns now.
            {:reply, :ok, state}

          :error ->
            # Recorded sleep, completion not yet stored. Suspend on this id.
            suspend(state, recorded.result_completion_id, from)
        end

      :processing ->
        cid = state.next_completion_id

        cmd = %Pb.SleepCommandMessage{
          wake_up_time: :os.system_time(:millisecond) + duration_ms,
          result_completion_id: cid
        }

        state = %{
          state
          | emitted: [cmd | state.emitted],
            next_completion_id: cid + 1
        }

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

  def handle_info({:handler_result, {:error, exception, stacktrace}}, state) do
    err = %Pb.ErrorMessage{
      code: 500,
      message: Exception.message(exception),
      stacktrace: Exception.format_stacktrace(stacktrace)
    }

    # ErrorMessage on its own is a terminal frame (per V5 spec it replaces
    # EndMessage). State-mutating commands emitted before the failure are
    # still part of the journal and remain in `state.emitted`.
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
  defp notification?(%Pb.RunCompletionNotificationMessage{}), do: true
  defp notification?(_), do: false

  defp notification_result(%Pb.SleepCompletionNotificationMessage{void: void}), do: void || :void
  defp notification_result(%{result: result}), do: result
  defp notification_result(_), do: :void

  defp command?(%mod{}) do
    name = Atom.to_string(mod)
    String.ends_with?(name, "CommandMessage")
  end

  # Highest existing completion_id in the replay journal + 1. Notifications
  # use the same id space as the commands that produced them, so we walk
  # both. For Week 3 only sleep allocates ids, but write the helper
  # generically so future commands plug in without changing this call site.
  defp starting_completion_id(frames) do
    frames
    |> Enum.flat_map(&extract_completion_ids/1)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp extract_completion_ids(%Frame{message: %{result_completion_id: id}}) when is_integer(id),
    do: [id]

  defp extract_completion_ids(%Frame{message: %{completion_id: id}}) when is_integer(id), do: [id]
  defp extract_completion_ids(_), do: []

  defp pop_recorded!([%expected_mod{} = head | rest], expected_mod), do: {head, rest}

  defp pop_recorded!([%mod{} | _], expected_mod) do
    raise "journal mismatch: expected #{inspect(expected_mod)}, got #{inspect(mod)}"
  end

  defp pop_recorded!([], expected_mod) do
    raise "journal mismatch: expected #{inspect(expected_mod)}, journal exhausted"
  end

  defp advance_phase(%{recorded_commands: []} = state), do: %{state | phase: :processing}
  defp advance_phase(state), do: state

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
