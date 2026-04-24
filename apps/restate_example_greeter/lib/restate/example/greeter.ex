defmodule Restate.Example.Greeter do
  @moduledoc """
  Counter Virtual Object — the Week 2 deliverable.

  Each Restate key (`/Greeter/<key>/count`) keeps its own counter in
  Restate's state store. Each invocation reads, increments, writes, and
  returns `"hello <n>"`. Persistence is end-to-end via Restate.
  """

  alias Restate.Context

  @doc """
  Increment the per-key counter and return a greeting string.

  Input is the JSON-decoded request body (ignored; the per-object key
  comes from `StartMessage.key`, which is the URL path segment).
  """
  def count(%Context{} = ctx, _input) do
    n = (Context.get_state(ctx, "counter") || 0) + 1
    Context.set_state(ctx, "counter", n)
    "hello #{n}"
  end
end
