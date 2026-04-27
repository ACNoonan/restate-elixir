defmodule Restate.TestServices.AwakeableHolder do
  @moduledoc """
  Mirror of `dev.restate.sdktesting.contracts.AwakeableHolder`. Used
  by tests to synchronize with the test runner via an awakeable —
  one handler creates an awakeable + registers its id here via
  `hold/2`; the test logic later calls `unlock/2` to resolve it.

  Three handlers, all `:exclusive` on the same VirtualObject key:

    * `hold(id)`         — store the awakeable id in state
    * `hasAwakeable()`   — bool: is an id stored?
    * `unlock(payload)`  — resolve the held awakeable; raises
                            `Restate.TerminalError` if none stored
  """

  alias Restate.Context

  @id_key "id"

  @doc """
  Test-harness helper — exercise the round-trip end-to-end without
  needing the full conformance suite. Creates an awakeable, calls
  `hold` on a peer AwakeableHolder key to register it, then awaits.
  Returns the value the awakeable was resolved with.

  Two-step usage from a client:

      curl -sS -X POST .../AwakeableHolder/k/echo_round_trip \\
        -H 'content-type: application/json' -d '"value-payload"'

  The handler creates an awakeable, calls
  `AwakeableHolder/<random>/hold(awakeable_id)` to stash it, then
  awaits the awakeable. The client (or a follow-up call) then hits
  `AwakeableHolder/<random>/unlock(payload)` to resolve it.
  """
  def echo_round_trip(%Context{} = ctx, _input) do
    # Plain self-test: create an awakeable, register it on the SAME key,
    # then immediately complete it from inside this handler. Tests the
    # signal-id routing without needing two interleaved invocations.
    {awakeable_id, handle} = Context.awakeable(ctx)
    Context.complete_awakeable(ctx, awakeable_id, %{ok: true})
    Context.await_awakeable(ctx, handle)
  end

  def hold(%Context{} = ctx, id) when is_binary(id) do
    Context.set_state(ctx, @id_key, id)
    nil
  end

  def has_awakeable(%Context{} = ctx, _input) do
    Context.get_state(ctx, @id_key) != nil
  end

  def unlock(%Context{} = ctx, payload) when is_binary(payload) do
    case Context.get_state(ctx, @id_key) do
      nil ->
        raise Restate.TerminalError, message: "No awakeable registered"

      awakeable_id ->
        Context.complete_awakeable(ctx, awakeable_id, payload)
        nil
    end
  end
end
