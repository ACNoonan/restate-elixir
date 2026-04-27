defmodule Restate.TestServices.MapObject do
  @moduledoc """
  Mirror of `dev.restate.sdktesting.contracts.MapObject`. Used by the
  `State.listStateAndClearAll` conformance test to validate that
  state writes are stored as separate Restate state entries (per the
  contract's docstring: "the individual entries should be stored as
  separate Restate state keys, and not in a single state key") and
  that `clear_all_state` plus state-key enumeration are implemented.
  """

  alias Restate.Context

  def set(%Context{} = ctx, %{"key" => key, "value" => value})
      when is_binary(key) and is_binary(value) do
    Context.set_state(ctx, key, value)
    nil
  end

  def get(%Context{} = ctx, key) when is_binary(key) do
    Context.get_state(ctx, key) || ""
  end

  def clear_all(%Context{} = ctx, _input) do
    entries =
      Context.state_keys(ctx)
      |> Enum.map(fn k -> %{key: k, value: Context.get_state(ctx, k) || ""} end)

    Context.clear_all_state(ctx)
    entries
  end
end
