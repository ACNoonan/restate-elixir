defmodule Restate.Server.Invocation do
  @moduledoc """
  One process per HTTP invocation. Owns the local state-map view and the
  list of journal entries to emit when the user handler returns.

  ## Lifecycle

      Endpoint → Invocation.start_link({start, input, mfa})
        ├─ Invocation spawns user handler in a linked process, passing it
        │  a `Restate.Context` whose pid is the Invocation
        ├─ Handler may call Context.get_state/2 → :persistent_term-style
        │  read from the local state_map seeded by StartMessage.state_map
        ├─ Handler may call Context.set_state/3 → updates the local map and
        │  queues a `SetStateCommandMessage` to emit
        └─ Handler returns or raises → Invocation builds the framed
           response (Output|Error + End) and replies to whoever's awaiting

  Week 2 deliberately skips full V5 replay/processing semantics. All
  journal entries we emit go on the wire fresh; we don't compare against
  pre-existing journal entries in the request body. That reconciliation
  arrives in Week 3 alongside sleep + suspension, which is when the
  Command/Notification correlation table actually starts to matter.
  """

  use GenServer

  alias Dev.Restate.Service.Protocol, as: Pb
  alias Restate.Protocol.Framer

  @doc """
  Start an invocation. `mfa` is `{module, function, arity}` — the function
  is called with `(%Restate.Context{}, input_value)`.

  `input_value` is the JSON-decoded handler input (or `nil` if the runtime
  sent an empty body).
  """
  @spec start_link({Pb.StartMessage.t(), term(), {module(), atom(), arity()}}) ::
          GenServer.on_start()
  def start_link({%Pb.StartMessage{}, _input, _mfa} = arg) do
    GenServer.start_link(__MODULE__, arg)
  end

  @doc """
  Block until the handler completes and return the framed response body
  (an iodata-friendly binary). Stops the invocation process on return.
  """
  @spec await_response(pid(), timeout()) :: binary()
  def await_response(pid, timeout \\ 30_000) do
    GenServer.call(pid, :await_response, timeout)
  end

  # --- GenServer ---

  @impl true
  def init({%Pb.StartMessage{state_map: state_entries}, input, mfa}) do
    state_map =
      for %Pb.StartMessage.StateEntry{key: k, value: v} <- state_entries, into: %{} do
        {k, v}
      end

    parent = self()

    handler_task =
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

    {:ok,
     %{
       state_map: state_map,
       emitted: [],
       awaiting_response: nil,
       result_body: nil,
       handler_task: handler_task
     }}
  end

  @impl true
  def handle_call({:get_state, key}, _from, state) do
    {:reply, Map.get(state.state_map, key), state}
  end

  @impl true
  def handle_call({:set_state, key, value_bytes}, _from, state) do
    cmd = %Pb.SetStateCommandMessage{key: key, value: %Pb.Value{content: value_bytes}}

    {:reply, :ok,
     %{
       state
       | state_map: Map.put(state.state_map, key, value_bytes),
         emitted: [cmd | state.emitted]
     }}
  end

  # The endpoint and the handler run concurrently — either could complete
  # first. We resolve the race by stashing whatever's missing.
  @impl true
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
