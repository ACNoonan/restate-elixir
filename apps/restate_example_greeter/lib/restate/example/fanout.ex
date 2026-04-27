defmodule Restate.Example.Fanout do
  @moduledoc """
  Demo 4 — high-concurrency fan-out (fire-and-forget shape).

  Two handlers on top of `ctx.send_async`:

    * `Restate.Example.Fanout.Orchestrator.run/2` — VirtualObject.
      Fires N `send_async` to leaves and returns immediately.
      Each `send_async` is one journaled OneWayCallCommandMessage —
      no HTTP round-trip per call. The orchestrator's wall-clock is
      essentially "time to write N journal entries."

    * `Restate.Example.Fanout.Leaf.process/2` — Service. Brief work
      (one `Context.set_state` for observability), then returns.

  ## What this demonstrates

  Restate runs the N leaves in parallel; the elixir-handler pod
  receives N concurrent HTTP POSTs, each handled by its own BEAM
  process tree (Plug request handler + Invocation GenServer +
  user-handler process). The pod's job is to sustain throughput —
  number of leaf invocations completed per second — without
  exploding memory.

  Each Restate-on-BEAM invocation ≈ 5 KB of heap (Bandit's request
  process + Invocation GenServer + spawn_linked handler).
  10,000 concurrent leaves ≈ 50 MB of process heap — comfortably
  fits a 256 MB pod. Equivalent Node.js workload retains 10,000
  closure scopes on a single heap; Promise-based fan-out at this
  scale typically OOMs without careful work-batching.

  ## Why fire-and-forget rather than awaitable fan-out

  v0.1 doesn't have awaitable combinators (`Awaitable.all` /
  `Awaitable.any`) — those are v0.2 work. The "fan-out and gather"
  shape (orchestrator awaits all N children's results) needs them
  to be efficient. Fire-and-forget skips the await dimension and
  measures pure throughput, which is what the BEAM concurrency
  story is about anyway.
  """

  defmodule Orchestrator do
    alias Restate.Context

    def run(%Context{} = ctx, %{"size" => n}) when is_integer(n) and n > 0 do
      Enum.each(1..n, fn task_id ->
        Context.send_async(ctx, "FanoutLeaf", "process", %{"task_id" => task_id})
      end)

      %{fired: n}
    end
  end

  defmodule Leaf do
    @doc """
    Brief leaf work — purely compute-bound, no journaled side effect.
    The harness measures throughput from container-stats observation:
    when CPU drops to idle, the leaf queue has drained.
    """
    def process(_ctx, %{"task_id" => task_id}) when is_integer(task_id) do
      %{task_id: task_id, ok: true}
    end
  end
end
