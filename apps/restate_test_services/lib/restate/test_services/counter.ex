defmodule Restate.TestServices.Counter do
  @moduledoc """
  Mirror of `dev.restate.sdktesting.contracts.Counter` from
  [restatedev/sdk-test-suite](https://github.com/restatedev/sdk-test-suite).

  Used by the conformance harness — the `State` test class exercises
  these handlers and asserts the journal-replay invariants.

  Wire names match the contract exactly (`add`, `addThenFail`, `get`,
  `reset`); the underlying Elixir function names are snake_case via the
  registration map.
  """

  alias Restate.Context

  @counter_key "counter"

  def add(%Context{} = ctx, value) when is_integer(value) do
    old_value = Context.get_state(ctx, @counter_key) || 0
    new_value = old_value + value
    Context.set_state(ctx, @counter_key, new_value)
    %{oldValue: old_value, newValue: new_value}
  end

  def add_then_fail(%Context{} = ctx, value) when is_integer(value) do
    old = Context.get_state(ctx, @counter_key) || 0
    Context.set_state(ctx, @counter_key, old + value)

    # Mirror Java: throw TerminalException(objectKey()).
    # UserErrors.setStateThenFailShouldPersistState asserts the error
    # message is the per-VirtualObject key.
    raise Restate.TerminalError, message: Context.key(ctx)
  end

  def get(%Context{} = ctx, _input) do
    Context.get_state(ctx, @counter_key) || 0
  end

  def reset(%Context{} = ctx, _input) do
    Context.clear_state(ctx, @counter_key)
    nil
  end
end
