defmodule Restate.Awaitable do
  @moduledoc """
  Combinators for waiting on multiple journaled async operations.

  Mirrors Java's `Awaitable.any` / `Awaitable.all` (see
  `sdk-java/.../AsyncResults.java`). The handles come from
  deferred-emit Context functions:

    * `Restate.Context.timer/2`        — `{:timer_handle, cid}`
    * `Restate.Context.call_async/5`   — `{:call_handle, result_cid, invok_cid}`
    * `Restate.Context.awakeable/1`    — `{:awakeable_handle, signal_id}`

  A `{:resolved, {:ok, value} | {:terminal_error, exc}}` handle is also
  accepted — for callers (like the conformance command-interpreter)
  that need to compose synchronously-resolved values into an `any/all`
  set without breaking the type.

  Operations on handles:

    * `await/2` / `any/2` / `all/2` — consume the handle's result.
    * `invocation_id/2` — for `:call_handle` only: return the
      callee's invocation id (e.g. for `Restate.Context.cancel_invocation/2`).

  ## Cancellation semantics

  All three primitives respect the V5 cancel signal:

    * If a completion is already in the journal, return it.
    * If all required completions are still pending and the
      invocation has been cancelled, raise `Restate.TerminalError{
      code: 409, message: \"cancelled\"}`. For any in-flight
      `:call_handle`s the SDK first emits
      `SendSignalCommandMessage{idx: 1}` to the callee so cancel
      cascades through the call tree.
    * Otherwise emit a `SuspensionMessage` listing the union of
      `waiting_completions` and `waiting_signals` (always plus
      signal_id 1 for cancel) and let the runtime re-invoke us.
  """

  @type ok_or_error :: {:ok, term()} | {:terminal_error, Restate.TerminalError.t()}

  @type handle ::
          {:timer_handle, non_neg_integer()}
          | {:call_handle, non_neg_integer(), non_neg_integer()}
          | {:awakeable_handle, non_neg_integer()}
          | {:resolved, ok_or_error()}

  @doc """
  Block until `handle` is complete and return its value. Raises
  `Restate.TerminalError` if the handle resolved with a failure.

  Equivalent to the auto-await done by `Context.sleep/2`,
  `Context.call/5`, and `Context.await_awakeable/2`, but works on
  any handle including `Context.timer/2` and
  `Context.call_async/5`.
  """
  @spec await(Restate.Context.t(), handle()) :: term()
  def await(%Restate.Context{pid: pid}, handle) do
    pid
    |> GenServer.call({:await_handles, :one, [handle]}, :infinity)
    |> unwrap_one()
  end

  @doc """
  Block until any of `handles` completes. Returns
  `{index, value}` where `index` is the position in the input list
  (zero-based). Raises `Restate.TerminalError` only if the *winning*
  handle resolved with a failure — the other handles' values are
  still waitable via subsequent calls.

  ## Use

      timer    = Restate.Context.timer(ctx, 100)
      {_id, a} = Restate.Context.awakeable(ctx)
      case Restate.Awaitable.any(ctx, [a, timer]) do
        {0, value}  -> value           # awakeable fired first
        {1, :ok}    -> :timeout         # timer fired first
      end
  """
  @spec any(Restate.Context.t(), [handle()]) :: {non_neg_integer(), term()}
  def any(%Restate.Context{pid: pid}, handles) when is_list(handles) and handles != [] do
    case GenServer.call(pid, {:await_handles, :any, handles}, :infinity) do
      {:ok, {:any, idx, value}} ->
        {idx, value}

      {:any_terminal_error, _idx, %Restate.TerminalError{} = exc} ->
        raise exc

      {:terminal_error, %Restate.TerminalError{} = exc} ->
        raise exc
    end
  end

  @doc """
  Block until every handle in `handles` completes. Returns the list
  of values in input order. If any handle resolves with a failure,
  raises that `Restate.TerminalError` immediately — sibling handles
  are abandoned (their completions still get journaled by the
  runtime, just not awaited).

  This is the primitive for fan-out + gather:

      handles = Enum.map(1..n, fn _ ->
        {id, h} = Restate.Context.awakeable(ctx)
        Restate.Context.send_async(ctx, "Leaf", "do_work", id)
        h
      end)
      results = Restate.Awaitable.all(ctx, handles)
  """
  @spec all(Restate.Context.t(), [handle()]) :: [term()]
  def all(%Restate.Context{pid: pid}, handles) when is_list(handles) do
    case GenServer.call(pid, {:await_handles, :all, handles}, :infinity) do
      {:ok, values} when is_list(values) ->
        values

      {:terminal_error, %Restate.TerminalError{} = exc} ->
        raise exc
    end
  end

  @doc """
  Block until the runtime has assigned an invocation id to the
  callee of a `Restate.Context.call_async/5` and return it.

  The returned id is the same string `Restate.Context.send/5` would
  hand back synchronously, and is the right value to pass to
  `Restate.Context.cancel_invocation/2` to cancel the callee
  out-of-band — typical use is to stash it in
  `Restate.Context.set_state/3` so a sibling `@Shared` handler can
  look it up and cancel.

  Costs one round-trip on the
  `CallInvocationIdCompletionNotificationMessage` (same as
  `Context.send/5`); on a replay where the notification is already
  in the journal, returns synchronously without suspending. Repeated
  calls on the same handle are journal-replay-safe — the cached
  notification is reused, no duplicate journal entries.

  Only valid on `:call_handle`s. `:timer_handle` and
  `:awakeable_handle` raise `ArgumentError`: timers and awakeables
  don't spawn invocations, so there's no id to return.

  Raises `Restate.TerminalError{code: 409, message: "cancelled"}` if
  the parent invocation gets cancelled while awaiting the id.
  """
  @spec invocation_id(Restate.Context.t(), {:call_handle, non_neg_integer(), non_neg_integer()}) ::
          String.t()
  def invocation_id(%Restate.Context{pid: pid}, {:call_handle, _result_cid, invok_cid})
      when is_integer(invok_cid) do
    case GenServer.call(pid, {:await_invocation_id, invok_cid}, :infinity) do
      {:ok, id} when is_binary(id) -> id
      {:terminal_error, %Restate.TerminalError{} = exc} -> raise exc
    end
  end

  def invocation_id(%Restate.Context{}, handle) do
    raise ArgumentError,
          "Restate.Awaitable.invocation_id/2 only accepts :call_handle handles " <>
            "from Restate.Context.call_async/5; got: #{inspect(handle)}"
  end

  defp unwrap_one({:ok, value}), do: value
  defp unwrap_one({:terminal_error, %Restate.TerminalError{} = exc}), do: raise(exc)
end
