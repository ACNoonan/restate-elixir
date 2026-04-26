defmodule Restate.Example.NoisyNeighbor do
  @moduledoc """
  Demo 2 (per [PLAN.md](../../PLAN.md#demos-beyond-the-mvp--making-the-beam-case))
  — handler variants for the noisy-neighbor isolation experiment.

  Two handlers on the same VirtualObject:

    * `light/2` — quick state read/write/return. Should complete in
      milliseconds under any load.
    * `poisoned/2` — tight CPU-bound tail-recursion for ~5 seconds.
      Saturates one BEAM scheduler per running invocation.

  ## The experiment

  Fire N concurrent `light` invocations with random keys plus M
  concurrent `poisoned` invocations (also random keys, different
  service-instances → no per-key serialization between them). Plot
  P50 / P99 / P999 of the `light` cohort.

  ## What we expect

  On the BEAM, scheduler preemption interrupts each poisoned process
  every ~2,000 reductions (sub-millisecond). 5 poisoned processes
  saturate ≤4 schedulers on a typical 4-core machine, but light
  invocations still get scheduler time — they queue, they don't block.
  P99 of the light cohort should stay in tens of milliseconds even
  with active poisoning.

  Compare with a single-event-loop runtime (Node.js, Python sync,
  Ruby): one 5-second CPU-bound handler blocks every other in-flight
  request for the full 5 seconds. P99 spikes to 5 s+ for the duration.
  """

  alias Restate.Context

  @poison_duration_ms 5_000

  def light(%Context{} = ctx, _input) do
    n = (Context.get_state(ctx, "n") || 0) + 1
    Context.set_state(ctx, "n", n)
    %{n: n}
  end

  def poisoned(%Context{} = _ctx, _input) do
    burn_until(:os.system_time(:millisecond) + @poison_duration_ms, 0)
  end

  defp burn_until(deadline, acc) do
    if :os.system_time(:millisecond) < deadline do
      burn_until(deadline, acc + 1)
    else
      %{iterations: acc, duration_ms: @poison_duration_ms}
    end
  end
end
