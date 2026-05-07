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

  ## Fire-and-forget vs awaitable fan-out

  Two demos sit side-by-side:

    * `Orchestrator.run/2` (fire-and-forget) — N `ctx.send_async`
      and return. Pure throughput shape; no gather. The number we
      brag about: 20K in-flight invocations on a single 256 MB pod.

    * `Orchestrator.gather/2` (fan-out + gather) — N awakeables,
      N children, then `Restate.Awaitable.all/2` over the awakeable
      handles. Two HTTP round-trips on the orchestrator regardless of
      N: pass 1 emits N OneWayCalls + a Suspension whose
      `waiting_signals` lists every child signal id; pass 2 finds
      every signal already resolved and emits the aggregated Output.
      Before the v0.2 combinator landed this gather was a literal
      `Enum.map(handles, &Context.await_awakeable/2)` — same wire
      shape (since Restate replays through completed signals
      linearly anyway in REQUEST_RESPONSE mode), but the API now
      reads as one `Awaitable.all` call instead of a hand-rolled
      loop. The optimisation moves to v0.3 if/when we lift the
      streaming-resume restriction.
  """

  defmodule Orchestrator do
    use Restate.Service, name: "FanoutOrchestrator", type: :virtual_object
    alias Restate.Context

    @handler type: :exclusive
    def run(%Context{} = ctx, %{"size" => n}) when is_integer(n) and n > 0 do
      # Typed call wrapper from `use Restate.Service`: a typo'd handler
      # name (e.g. `send_proces/2`) is a compile error here, instead
      # of a runtime 404 from the runtime when the fan-out actually
      # fires.
      Enum.each(1..n, fn task_id ->
        Restate.Example.Fanout.Leaf.Caller.send_process(ctx, %{"task_id" => task_id})
      end)

      %{fired: n}
    end

    @doc """
    Awakeable-based fan-out + gather. Distinct from `run/2` which is
    fire-and-forget.

    Allocates N awakeables, fires N children (each carrying its
    awakeable id), awaits them all, returns the aggregated child
    results.

    HTTP round-trip accounting on the orchestrator side, regardless of N:

      Pass 1: emit N OneWayCalls + Suspension(waiting_signals: [17])
              (the orchestrator only needs to suspend on the first
              awakeable; once any one arrives, the next replay will
              find every signal that arrived in the meantime)
      Pass 2: replay through every await — they all find their signal
              already in the notifications table — emit aggregated
              Output + End.

    So 2 round-trips fixed, the rest is Restate-side parallelism.

    Predicted Node.js equivalent: each `Promise.all`-style await
    retains a closure scope per outstanding leaf (N closures on the
    heap). Our Elixir orchestrator holds N tuples of
    `{task_id, awakeable_id, handle}` (~50 B each), then walks them
    in a flat enum. Memory delta in N is linear and tiny.
    """
    @handler type: :exclusive
    def gather(%Context{} = ctx, %{"size" => n}) when is_integer(n) and n > 0 do
      awakeables =
        Enum.map(1..n, fn task_id ->
          {id, handle} = Context.awakeable(ctx)
          {task_id, id, handle}
        end)

      Enum.each(awakeables, fn {task_id, awakeable_id, _handle} ->
        Restate.Example.Fanout.Leaf.Caller.send_complete(ctx, %{
          "task_id" => task_id,
          "awakeable_id" => awakeable_id
        })
      end)

      handles = Enum.map(awakeables, fn {_task_id, _id, handle} -> handle end)
      results = Restate.Awaitable.all(ctx, handles)

      %{
        gathered: length(results),
        sample: List.first(results)
      }
    end
  end

  defmodule Leaf do
    use Restate.Service, name: "FanoutLeaf", type: :service
    alias Restate.Context

    @doc """
    Fire-and-forget leaf — pure compute, no journaled side effect.
    Used by `Orchestrator.run/2`.
    """
    @handler []
    def process(_ctx, %{"task_id" => task_id}) when is_integer(task_id) do
      %{task_id: task_id, ok: true}
    end

    @doc """
    Awakeable-completing leaf — used by `Orchestrator.gather/2`.
    Computes a result and signals it back to the parent via the
    awakeable id passed in the input.
    """
    @handler []
    def complete(%Context{} = ctx, %{"task_id" => task_id, "awakeable_id" => awakeable_id})
        when is_integer(task_id) and is_binary(awakeable_id) do
      Context.complete_awakeable(ctx, awakeable_id, %{
        task_id: task_id,
        result: "leaf-#{task_id}"
      })

      nil
    end
  end
end
