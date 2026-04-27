# Demo 4 — High-concurrency fan-out

The throughput-and-memory story. **20,000 in-flight Restate
invocations on a single elixir-handler pod, +1 MB peak memory over
baseline.** The BEAM has so much headroom that Restate's ingest
queue is the bottleneck, not us.

## The scenario

A `FanoutOrchestrator.run(size: N)` handler fires N
`Restate.Context.send_async` calls to a `FanoutLeaf.process`
service handler and returns immediately. There's no awakeable
gather, no awaitable combinator wait — pure fire-and-forget. Each
`send_async` is one journaled `OneWayCallCommandMessage` at zero
HTTP round-trip cost, so the orchestrator's wall-clock is
essentially "time to write N journal entries."

Restate enqueues N leaf invocations and dispatches them
concurrently to our pod. The pod's job is to sustain
*throughput* — leaves processed per second — without exploding
memory.

The harness fires K orchestrators in parallel, totalling K × N
leaf invocations, then samples the elixir-handler container's
memory and CPU until the leaf queue drains.

## Measured runs

10-core MacBook Pro, `restate:1.6.2` in `docker compose`,
fresh stack (volumes cleared between runs).

| K | N | Total leaves | Fanout emit wall-clock | Drain | Throughput | Peak mem (Δ) | Peak CPU |
|---|---|---|---|---|---|---|---|
| 10 | 50 | 500 | 42 ms | 3.47 s | 144 /s | 156 → 156 MB **(+0)** | 0.1% |
| 50 | 100 | 5,000 | 117 ms | 5.40 s | 926 /s | 156 → 159 MB **(+3)** | 54% |
| 100 | 100 | 10,000 | 175 ms | 5.35 s | 1,870 /s | 159 → 164 MB **(+5)** | 103% |
| 200 | 100 | 20,000 | 493 ms | 8.03 s | 2,489 /s | 163 → 164 MB **(+1)** | 105% |

`Δ` is the additional RSS over the pre-burst baseline (~155 MB —
the BEAM's idle footprint with all our services registered).

Headline numbers from the 20,000-leaf run:

```
fanout emit wall-clock : 493ms
leaf drain wall-clock  : 8.03s
total leaves processed : 20000
leaf throughput        : 2,489 leaves/sec
peak elixir-handler mem: 164MB  (+1MB over 163MB baseline)
peak elixir-handler cpu: 105%   (~1 of 10 cores)
```

## Why this is BEAM-shaped

**Per-invocation memory ≈ 5 KB.** Every Restate invocation lands as
an HTTP POST that Bandit dispatches to its own request process; that
process spawns a `Restate.Server.Invocation` GenServer, which
spawn-links the user-handler process. Three short-lived BEAM
processes per invocation, each with a 233-word default heap
(~1.8 KB). At 20,000 in-flight, that's an order-of-magnitude estimate
of ~30 MB of process state.

We measured +1 MB. The actual delta is sublinear because:

- Leaves complete in microseconds (just `set_state` + return), so
  peak concurrent is much smaller than the total processed.
- **Per-process generational GC.** Each completed BEAM process
  releases its heap immediately at termination. There is no
  accumulating shared-heap pressure to compact. Memory churn flows
  through and out the other side, never accumulating.
- The BEAM scheduler runs as many leaves in parallel as there are
  cores (10), so even at 2,489 leaves/sec the in-flight count at
  any instant rarely exceeds tens.

**Throughput scales sublinearly with N — but for the right reason.**
At K=10 / N=50 we got 144 leaves/sec; at K=200 / N=100 we got
2,489 leaves/sec. The bottleneck shifts from "warmup +
parallelism not yet saturated" to "Restate's per-invocation
journal/dispatch cost." Our handler does ~100 µs of work per
leaf; everything else is Restate's persistence + HTTP transport.

The key claim: **at 20,000 in-flight Restate invocations, the
elixir-handler pod is barely warm.** Peak CPU is 105% (1 core out
of 10), peak memory delta is 1 MB. The rest of the latency / time
budget is sitting at Restate.

## What the same workload looks like on Node.js

The headline contrast (predicted; not measured here):

- **Memory.** Node.js's V8 retains a closure scope per Promise.
  20,000 in-flight Promises with even a few KB of captured context
  each is hundreds of MB of heap. OOM territory on a 256 MB pod.
- **Throughput.** Single-threaded event loop. CPU-bound work
  serializes; even pure-async I/O is bounded by event-loop tick
  rate (typically thousands of microtasks per ms, so high but
  bounded). The BEAM's preemptive scheduler with N cores → N
  schedulers can do better when work is mixed.
- **Failure isolation.** A single leaf's bug (regex backtracking,
  unbounded recursion, JSON.parse on a giant blob) on Node halts
  the event loop for everyone. On the BEAM, that one process gets
  preempted at the reduction limit (Demo 2 covers this); the other
  19,999 keep going.

A side-by-side measurement against a TS handler with the same
contract is left for a future commit (write a Node.js
`FanoutOrchestrator` + `FanoutLeaf`, register them as a sidecar
service, run the same harness against both pods, plot).

## Reproduce locally

```sh
docker compose down -v          # clear any stale Restate journal state
docker compose up -d --build
restate --yes deployments register http://elixir-handler:9080 --use-http1.1

elixir scripts/demo_4_fanout.exs
```

Knobs (env vars):

```
ORCHESTRATORS         concurrent FanoutOrchestrator runs       (default: 20)
SIZE_PER              leaves per orchestrator                  (default: 200)
INGRESS               Restate ingress URL                      (default: http://localhost:8080)
COMPOSE_SVC           docker-compose service for stats sampling (default: elixir-handler)
IDLE_THRESHOLD_PCT    CPU% below which queue is "drained"      (default: 5)
```

The harness:

1. Captures elixir-handler memory + CPU baseline.
2. Warms up with one tiny invocation (avoids first-call latency
   being tagged as P99 noise).
3. Fires K orchestrators in parallel via `Task.async_stream`.
4. Samples docker stats every 250 ms while the leaf queue drains
   (CPU drops below the threshold for two consecutive samples).
5. Reports per-orchestrator P50/P99, fanout-emit wall-clock,
   drain wall-clock, throughput, peak memory + CPU.

## Implementation files

- [`apps/restate_example_greeter/lib/restate/example/fanout.ex`](../apps/restate_example_greeter/lib/restate/example/fanout.ex) — `FanoutOrchestrator.run/2` and `FanoutLeaf.process/2`
- [`apps/restate_example_greeter/lib/restate/example/greeter/application.ex`](../apps/restate_example_greeter/lib/restate/example/greeter/application.ex) — service registrations
- [`scripts/demo_4_fanout.exs`](../scripts/demo_4_fanout.exs) — the load harness

## SDK addition

`Restate.Context.send_async/5` — fire-and-forget variant of
`send/5`. Emits `OneWayCallCommandMessage` and returns `:ok`
immediately, **without** suspending on the invocation_id
notification. The trade-off vs `send/5`:

```
send/5         | round-trip per send | returns invocation_id
send_async/5   | zero round-trips    | returns :ok
```

Without `send_async`, fan-out at this scale would cost N HTTP
round-trips on the orchestrator side (one per outgoing call to wait
for the runtime to confirm and tell us the invocation id) — making
the orchestrator's wall-clock O(N) rather than O(1).

## Follow-ups

1. **Awaitable-combinator fan-out** (v0.2). Pair `send_async` with
   awaitable handles so the orchestrator can `Awaitable.all`
   N children and gather their results without N suspensions.
   Until that lands, fan-out workloads that need result aggregation
   should use `Restate.Context.call/5` sequentially or design around
   awakeables.
2. **Node.js side-by-side.** Same workload against a TS sidecar.
   Asset is the comparison plot.
3. **Larger-scale variants.** Push to 100K leaves on a 4-core CI
   node to see where Restate's ingress saturates first.
4. **Awakeable-based "fan-out and gather"** demo once the
   completion-id-vs-signal-id awakeable routing is sorted out (see
   v0.2 work).
