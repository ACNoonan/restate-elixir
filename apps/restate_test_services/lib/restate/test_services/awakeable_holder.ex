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
