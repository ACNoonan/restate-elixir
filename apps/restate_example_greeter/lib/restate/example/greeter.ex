defmodule Restate.Example.Greeter do
  @moduledoc """
  Counter + durable-sleep Virtual Object.

  Two handlers:

    * `count/2` — Week 2 counter. Read/increment/write per-key state and
      return `"hello <n>"`.
    * `long_greet/2` — Week 3 durability demo. Records a journal step,
      sleeps 10 seconds, records another step, returns `"hello <name>"`.
      The sleep is durable: kill the pod mid-sleep and the runtime
      replays the journal on the next invocation; the handler resumes
      past the completed sleep.
  """

  use Restate.Service, type: :virtual_object
  alias Restate.Context

  @sleep_ms 10_000

  @handler type: :exclusive
  def count(%Context{} = ctx, _input) do
    n = (Context.get_state(ctx, "counter") || 0) + 1
    Context.set_state(ctx, "counter", n)
    "hello #{n}"
  end

  @handler type: :exclusive
  def long_greet(%Context{} = ctx, name) do
    Context.set_state(ctx, "step", "started")
    Context.sleep(ctx, @sleep_ms)
    Context.set_state(ctx, "step", "after_sleep")
    "hello #{name}"
  end
end
