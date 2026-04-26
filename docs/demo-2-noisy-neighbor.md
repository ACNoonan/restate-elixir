# Demo 2 — Noisy-neighbor isolation

The first BEAM-differentiated asset. Pod-kill durability (Demo 1)
proves protocol conformance; every Restate SDK passes that. **This
demo is something a single-event-loop runtime can't do.**

## The scenario

One handler pod, two coexisting handlers on the same VirtualObject:

| Handler | What it does | Wall-clock cost per call |
|---|---|---|
| `light/2`  | read state, increment, write state, return `%{n: n}` | sub-millisecond on the BEAM |
| `poisoned/2` | tail-recursive tight loop for 5,000 ms (no IO, no yield) | 5 s of CPU per call, per scheduler |

Workload (defaults; configurable via env):

- 1,000 concurrent `light` invocations, each on a unique VirtualObject key
- 10 concurrent `poisoned` invocations during phase B, also unique keys → no per-key lock contention

The host has 10 CPU cores → 10 BEAM schedulers. **10 poisoned
invocations saturate every scheduler simultaneously.** The premise
of the demo is: do the 1,000 light invocations still complete
quickly while every scheduler is being hammered?

## What we measured

```
$ elixir scripts/demo_2_noisy_neighbor.exs
```

Run on a 10-core MacBook Pro against `restate:1.6.2` in `docker compose`. Two phases, after a 200-request warm-up:

```
phase A — baseline (no poisoning)
  wall-clock         : 223.34ms
  light invocations  : 1000 (success: 1000, failures: 0)
  P50  / P99  / P999 : 187.40ms / 208.21ms / 210.18ms
  min  / max         : 88.28ms / 210.37ms

phase B — under 10 poisoned handlers (saturating all 10 schedulers)
  wall-clock         : 335.95ms
  light invocations  : 1000 (success: 1000, failures: 0)
  P50  / P99  / P999 : 185.83ms / 318.35ms / 327.61ms
  min  / max         : 64.50ms / 328.37ms
```

| Percentile | Baseline | Under poisoning | Ratio |
|---|---|---|---|
| P50  | 187.40 ms | 185.83 ms | **0.99×** |
| P99  | 208.21 ms | 318.35 ms | **1.53×** |
| P999 | 210.18 ms | 327.61 ms | **1.56×** |
| max  | 210.37 ms | 328.37 ms | 1.56× |

**The median light invocation doesn't notice the poisoning at all
(P50 ratio: 0.99×).** Only the tail of the distribution shifts —
the slowest 1% of light requests see ~50% longer latency, from 208
ms to 318 ms.

## Why this happens

Three properties of the BEAM combine to produce that distribution:

**1. Preemptive scheduling at the reduction-counter level.** Every
function call, list operation, send, receive, etc. costs 1 reduction.
After ~2,000 reductions, the BEAM scheduler interrupts the running
process — *regardless of what it's doing* — and gives the next
process a turn. Our `poisoned` handler does pure tail recursion, so
it accumulates reductions fast (10⁸+ per second per core); it gets
preempted thousands of times per second.

**2. Per-process isolation.** Each Restate invocation runs in its own
~2 KB BEAM process. There's no shared event loop, no shared call
stack, no shared microtask queue. A poisoned process at 100% CPU is
just one process competing for scheduler time, not a barrier blocking
every other process from progressing.

**3. Multi-scheduler.** With 10 schedulers on a 10-core machine, the
BEAM can run 10 processes truly in parallel. Even when 10 poisoned
processes saturate every scheduler, the scheduler still rotates
through the 1,000 ready light processes — they just queue, they don't
block.

Result: **light invocations get less CPU time, but they always get
some.** Latency shifts; it doesn't blow up.

## What a single-event-loop runtime would show

Same workload, against a Node.js / Python-sync / Ruby handler:

- Node.js has one event loop. A 5-second CPU-bound function returns
  control to the loop only when it returns. While `poisoned` runs,
  every queued request waits — including all 1,000 in-flight `light`
  requests that arrive during that window.
- 10 poisoned calls land sequentially (or near-sequentially in the
  microtask queue), each holding the loop for 5 s.
- Total blocking window: ~50 s of cumulative wall-clock during which
  no light request can make any progress.

Predicted P99 of `light` cohort: **~5,000 ms+** (the full block
window). Ratio vs baseline: **~25×**.

We didn't run that experiment yet — building a TS handler with
the same shape and registering it as a sidecar service is a follow-up
(see `PLAN.md` Demo 2 spec). The Elixir number stands on its own:
**1.53× under saturation of every scheduler simultaneously, no
failures, no timeouts.**

## Reproduce locally

```sh
# 1. Bring up a fresh stack
docker compose up -d --build
restate --yes deployments register http://elixir-handler:9080 --use-http1.1

# 2. Run the harness
elixir scripts/demo_2_noisy_neighbor.exs
```

Knobs (env vars):

```
LIGHT_COUNT     concurrent light invocations             (default: 1000)
POISONED_COUNT  concurrent poisoned during phase B        (default: 10)
WARMUP_COUNT    discarded primer for connection pool      (default: 200)
INGRESS         Restate ingress URL                       (default: http://localhost:8080)
OUT_DIR         where the script writes per-request CSVs  (default: /tmp)
```

The script writes:

- `/tmp/demo_2_baseline.csv` — per-request latencies for phase A
- `/tmp/demo_2_poisoned.csv` — per-request latencies for phase B

Each row: `duration_ms,status,detail`. Suitable for piping into a
plotting tool of your choice.

## Implementation files

- [`apps/restate_example_greeter/lib/restate/example/noisy_neighbor.ex`](../apps/restate_example_greeter/lib/restate/example/noisy_neighbor.ex) — `light/2` and `poisoned/2`
- [`apps/restate_example_greeter/lib/restate/example/greeter/application.ex`](../apps/restate_example_greeter/lib/restate/example/greeter/application.ex) — `NoisyNeighbor` service registration
- [`scripts/demo_2_noisy_neighbor.exs`](../scripts/demo_2_noisy_neighbor.exs) — the load harness

## Follow-ups

1. **TS sidecar comparison.** Write a Node.js handler with the same
   `light` / `poisoned` contract, register it on the same Restate
   runtime, run the same workload, plot side-by-side. Estimated:
   half day of work. The asset is the comparison plot.
2. **Larger machine variants.** This run is on 10 cores. Repeat on
   a 4-core CI node and a 32-core server. Expectation: the BEAM
   ratio rises modestly as poisoning saturation exceeds CPU count;
   still bounded.
3. **`Demo.Bench` Mix task.** Move the script into a Mix task with
   structured output (JSON + Markdown) so CI can run it on every
   PR and compare vs main.
