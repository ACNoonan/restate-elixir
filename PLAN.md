# Plan — restate-elixir MVP

Initial MVP scope, kept deliberately narrow.

> **Status update (v0.2.0).** This document is the original v0.1 plan, preserved for the warm-intro conversation as historical context. v0.2 shipped beyond the MVP scope below — Workflow service type, lazy state, the `oneWayCallWithDelay` proxy fix, awaitable combinators, `ctx.run` retry policies + flush, cancellation surface, and Demos 2-5 all landed. **49 / 49 conformance tests pass.** Open carryovers are HTTP/2 same-stream streaming (v0.3), V6 protocol, Lambda transport, and deeper production hardening. See [README.md](./README.md) for the current implementation matrix.

## MVP scope

### In

- Restate **service protocol V5** (current; ~37 message types in three namespaces — control / Command / Notification — plus the custom-entry range starting at `0xFC00`). Targets current `restate-server` (verified against 1.6.2).
- **Service** type (stateless handlers)
- **Virtual Object** type (keyed stateful handlers with serialized concurrency per key)
- Journaled primitives: `get_state` (eager via `StartMessage.state_map`), `set_state`, `sleep`, `call`, `run`, `awakeable`
- HTTP/2 endpoint via [Bandit](https://github.com/mtrudel/bandit)
- Discovery manifest at `GET /discover`
- Conformance: a subset of scenarios from [restatedev/sdk-test-suite](https://github.com/restatedev/sdk-test-suite)
- Local `kind` cluster as the durability test bed

### Out (originally deferred to v0.2+)

- **Workflow** service type ✓ **shipped in v0.2** — `WorkflowAPI.setAndResolve` conformance test green, durable promises (`get_promise` / `peek_promise` / `complete_promise` / `reject_promise`) wired
- Lazy state ✓ **shipped in v0.2** — `GetLazyStateCommandMessage` + `GetLazyStateKeysCommandMessage`, honors `StartMessage.partial_state`; `State × 3` × `lazyState` + `lazyStateAlwaysSuspending` matrices both green
- Lambda transport — still deferred
- V6 protocol (superset of V5; advertise V5 only for now) — still deferred
- Production hardening (observability, backpressure tuning, graceful shutdown edge cases) — partial: `DrainCoordinator` + SIGTERM trap shipped (Demo 3); deeper observability + backpressure tuning still ahead

## Positioning

**Target user:** teams already running Restate services in TS / Java / Go who want to add Elixir handlers to a polyglot estate.

Not trying to win the Elixir-greenfield durable-workflow market against Oban or native alternatives like `wavezync/durable`. Those are crowded lanes with mature or rising players. This SDK's value is enabling Elixir as a first-class citizen of polyglot Restate deployments — which nobody else offers.

## Reference material

- **Protocol protos (V5/V6 canonical)**: [restatedev/sdk-shared-core](https://github.com/restatedev/sdk-shared-core) — `service-protocol/dev/restate/service/protocol.proto`. Vendored at `apps/restate_protocol/proto/`; `UPSTREAM` records the exact source commit and refresh procedure.
- **Reference port target**: [restatedev/sdk-java](https://github.com/restatedev/sdk-java) — the only SDK with a pure-language state machine (~5k LOC in `sdk-core/src/main/java/dev/restate/sdk/core/statemachine/`). The Rust/TS/Python/Go SDKs all wrap a shared Rust core (`sdk-shared-core`) via WASM / PyO3 / cdylib; Java is the right port target for an Elixir state machine. `MessageType.java` is the canonical type-ID table.
- **Conformance**: [restatedev/sdk-test-suite](https://github.com/restatedev/sdk-test-suite)
- **Restate architecture blog** (Feb 2025) — Stephan Ewen's own framing of the SDK as "a thin library, somewhat comparable to a KafkaConsumer or JDBC client."

## Week-by-week

### Week 0 — Setup (1 day) ✓

- Install `mise` or `asdf`; pin Elixir and Erlang/OTP versions
- Install [`kind`](https://kind.sigs.k8s.io/) for local K8s
- Install `docker`, `kubectl`, and the `restate` CLI from [restatedev/restate](https://github.com/restatedev/restate)
- Smoke test: pull Restate's TypeScript greeter example; run it against a local `restate-server` via `docker run restatedev/restate:latest`; invoke via `restate invocations invoke` and confirm it works end-to-end

Why: debugging "my Elixir handler doesn't work" is much easier after proving a known-good handler works against the same server.

### Week 1 — Foundations + non-durable echo ✓

Goal: an Elixir handler that responds to Restate invocations end-to-end in `docker-compose`.

- Scaffold Mix umbrella: `apps/restate_protocol`, `apps/restate_server`, `apps/restate_example_greeter`
- Vendor V5 `protocol.proto` from `restatedev/sdk-shared-core`
- Generate Elixir modules with [`elixir-protobuf/protobuf`](https://github.com/elixir-protobuf/protobuf)
- Hand-write the 8-byte message framer/deframer (~100 LOC; see `sdk-java/sdk-core/.../MessageEncoder.java` + `MessageDecoder.java`)
- Bandit serving `GET /discover` with a minimal service manifest (one service `Greeter`, one handler `greet`)
- Bandit serving `POST /invoke/Greeter/greet` that parses `StartMessage` + `InputCommandMessage`, immediately sends `OutputCommandMessage { value: "hello" }` + `EndMessage` — **no journal logic yet**, this is a non-durable echo
- `docker-compose.yml` with `restate-server:1.6.2` + Elixir app; register via `restate deployments register http://elixir-handler:9080`

**Deliverable:** `curl POST .../Greeter/greet '"world"'` returns `"hello"`. The wire format works.

### Week 2 — State primitives + first `kind` deploy ✓

Goal: real journal for `get_state` / `set_state`, running in a local K8s cluster.

- `:gen_statem` with `:replaying` and `:processing` states inside `Restate.Server.Invocation`
- Implement: `StartMessage` (with `state_map`), `InputCommandMessage`, `OutputCommandMessage`, `EndMessage`, `GetEagerStateCommandMessage`, `SetStateCommandMessage`, `CommandAckMessage`. Defer the lazy-state round-trip (`GetLazyStateCommandMessage` ↔ `GetLazyStateCompletionNotificationMessage`) — eager covers the counter demo and avoids the first Notification correlation work.
- Context API: `Restate.Context.get_state(ctx, "key")`, `set_state(ctx, "key", value)`. Each call is a `GenServer.call` to the invocation process; the state machine decides replay-from-journal vs emit-new-entry.
- `mix release` + `Dockerfile` (distroless or alpine base)
- **Move to kind**: `kind create cluster`; deploy Restate Server via the [Helm chart](https://github.com/restatedev/restate/tree/main/charts/restate); deploy the Elixir handler as Deployment + Service; register via a one-shot Job running `restate deployments register http://greeter-svc:9080`
- Example handler `greet/1` that reads a counter from state, increments it, writes it back, returns `"hello #{n}"`

**Deliverable:** counter handler working in `kind`; state persists across invocations.

### Week 3 — Sleep, suspension, journal replay — the durability demo

**This is the week the SDK becomes real.** This is also where V5's Command/Notification split lands properly: `SleepCommandMessage` records the timer, `SleepCompletionNotificationMessage` carries the firing notification, correlated by `completion_id` on both sides.

- Implement `SleepCommandMessage`, `SleepCompletionNotificationMessage`, `SuspensionMessage`, completion-id correlation
- Suspension semantics: when the handler is blocked on an uncompleted notification and has no more work to do, emit `SuspensionMessage { waiting_completions: [completion_id] }` and close the stream. On next invocation, replay journal, resume.
- Example `long_greet/1`:

  ```elixir
  def long_greet(ctx, name) do
    Restate.Context.set_state(ctx, "step", "started")
    Restate.Context.sleep(ctx, 10_000)
    Restate.Context.set_state(ctx, "step", "after_sleep")
    "hello #{name}"
  end
  ```

- **The demo (in kind):**
  1. `restate invocations invoke Greeter/long_greet '{"name": "world"}' --async`
  2. During the sleep: `kubectl delete pod elixir-handler-xyz --force --grace-period=0`
  3. kind restarts the pod; Restate re-invokes with the full journal
  4. Handler replays through `set_state("step", "started")` and the completed sleep entry from the journal; continues to `set_state("step", "after_sleep")`; returns `"hello world"`
  5. `restate state get Greeter/world step` → `"after_sleep"`
- Record the demo (asciinema or screen recording) — this is the asset for the Ewen conversation

**Deliverable:** durability demo recorded; pod kill mid-sleep proven to resume correctly.

### Week 4 — Conformance + warm-intro prep

- Clone `restatedev/sdk-test-suite`; configure it to point at the Elixir endpoint in `kind`; aim for 2–3 scenarios green (likely `greeter`, `counter`, `sleep`)
- README with `docker-compose up` and `kind create cluster && kubectl apply -f k8s/` quickstart paths
- Clean git history
- Draft the Ewen outreach message (see [docs/ewen-outreach-draft.md](./docs/ewen-outreach-draft.md))

**Deliverable:** repo is shareable; demo is recorded; warm-intro draft is ready.

## The Ewen conversation — not cold outreach

Plan: reach out after Week 4 with working code and a recorded demo. Frame should explicitly include:

- Link to the working repo with durability demo in K8s
- Technical thesis: BEAM's `:gen_statem` + OTP supervision + preemptive scheduling as native fit for Restate's state machine
- **Explicit ask for upstream absorption with a paid-maintainer or contractor arrangement.** The Temporal Erlang SDK precedent (18 months solo work, shipped behind €100/app/mo paywall, concluded commercially unviable as pure OSS) suggests sustained single-maintainer pure-OSS isn't viable for this shape of work. Name it; don't make Stephan guess.

## Demos beyond the MVP — making the BEAM case

Week 3's pod-kill demo is the table-stakes asset: it proves the V5 protocol works under failure in Elixir. Every Restate SDK survives the same scenario; the demo doesn't differentiate Elixir specifically.

The demos below extend that baseline to surface BEAM-specific operational properties — preemptive scheduling, per-process isolation, cheap concurrency, generational GC — by mapping each to a K8s pain point an SRE has already been bitten by. None were MVP scope; all shipped in v0.2 (writeups in `docs/demo-2…5-*.md`). Their job is to give the upstream-absorption pitch reasons beyond polyglot enablement.

Each entry follows: **Real-world pain** (the operational story) → **The demo** (what to build, what to measure) → **Why BEAM specifically** (the technical claim, with comparisons) → **Cost / dependencies**.

### Demo 1 — Pod kill mid-sleep ✓ (Week 3)

The current demo. Invoke `Greeter/world/long_greet`, `kubectl delete pod --force` mid-sleep, runtime re-invokes the new pod, journal replays past the completed sleep, returns `"hello world"`. Proves protocol conformance under failure. No BEAM-specific story — every SDK does this.

### Demo 2 — Noisy-neighbor isolation ✓ (v0.2)

> Shipped — see [docs/demo-2-noisy-neighbor.md](./docs/demo-2-noisy-neighbor.md). **Measured: P99 of the light cohort inflates to 1.53× under 10 saturating-CPU poisoned handlers; P50 stays at 0.99×.** The original plan is preserved below for context.


**Real-world pain.** "One pathological request took down our handler pod." On Node.js this shape of incident is regex backtracking, JSON-parse on a 100MB blob, an unbounded loop someone shipped on a Friday. The single-threaded event loop blocks; every other in-flight invocation stalls. P99 latency for unrelated traffic spikes for the duration of the bad request. Every SRE running Node in production has worn this pager.

**The demo.** One pod, two handler variants on the same `Greeter` service:

- `Greeter/<key>/light` — state read + sleep 100ms + state write
- `Greeter/<key>/poisoned` — tight CPU loop for 30s

Workload: 1,000 concurrent `light` invocations + 5 `poisoned` invocations interleaved. Plot P50 / P99 / P999 of the `light` cohort over time. On Elixir, the lines stay flat — the BEAM scheduler preempts each process at its reduction limit (~2,000 reductions, sub-millisecond) regardless of what it's doing. For comparison, ship a TS handler (or Python sync) on a sidecar pod doing the same workload mix; the comparison plot is the asset.

**Why BEAM specifically.** Preemptive scheduling at the runtime level. Node, Python sync, Ruby, and PHP all have cooperative-or-blocking models that this scenario breaks. Java handles it with thread pools but at ~1MB+ per thread (vs ~2KB per BEAM process) and with thread-pool-exhaustion as the new failure mode. Go is competitive — goroutines are cheap and preemption was added in 1.14 — but lacks per-process GC isolation, so a single goroutine allocating heavily can stall others through the shared GC.

**Cost / dependencies.** Medium. Needs the poisoned handler variant, a load generator (`hey` or a small Elixir script), Prometheus + Grafana for the plot. Comparison TS handler is optional but doubles the visual impact. No SDK changes — works on top of v0.1.

### Demo 3 — Graceful node drain ✓ (v0.2)

> Shipped — see [docs/demo-3-graceful-drain.md](./docs/demo-3-graceful-drain.md). **Measured: 20/20 in-flight `slow_op` invocations completed during a mid-flight drain inside the 3 s budget, no retries.** `Restate.Server.DrainCoordinator` + SIGTERM trap landed (~150 LoC). The original plan is preserved below for context.


**Real-world pain.** Every K8s upgrade. `kubectl drain` sends SIGTERM with `terminationGracePeriodSeconds` (default 30s). In-flight requests either finish-or-get-killed at grace expiry, or they hold up the drain past the SLO. Most SDKs don't gracefully suspend pending invocations on shutdown — they treat SIGTERM as "wrap up what you can, drop the rest." Restate's runtime can recover dropped work via re-invocation, but you take a latency hit while the stranded journal entries time out.

**The demo.** Three pods behind the same Restate Service. Kick off 100 `long_greet` invocations distributed across the pods. Mid-flight, `kubectl drain <node>` one of them.

The Elixir SDK traps SIGTERM at the `Restate.Server.Application` level, broadcasts a `:drain` signal to its Invocation supervisor, and each in-flight Invocation finishes its current journal step, emits `SuspensionMessage` with whatever completion-ids it's waiting on (or `EndMessage` if the handler finishes during the grace window), and closes cleanly. Restate routes the resumes to the surviving pods. The drain completes inside `terminationGracePeriodSeconds` with zero dropped work and zero retries from the runtime side.

Asset: a side-by-side timeline showing TS pod drain (X% of in-flight requests time out and get re-tried after retry-backoff) vs Elixir pod drain (100% migrate cleanly).

**Why BEAM specifically.** `Process.flag(:trap_exit, true)` + a supervisor that broadcasts a drain signal to its children is a 50-LOC idiom on the BEAM. The supervisor model means "for-each invocation, let it finish its current step, then close" is structurally natural. Doing the equivalent cleanly on Node requires hand-wiring shutdown coordination across every handler module; on Java, `Runtime.addShutdownHook` plus a thread-pool flush dance with timeouts. Goroutine equivalents exist but lack the supervisor abstraction; it's all manual `context.Context` plumbing.

**Cost / dependencies.** High — but high-value. Requires SDK-level work:

- `Process.flag(:trap_exit, true)` in `Restate.Server.Application` plus a SIGTERM handler that calls into a new `Restate.Server.DrainCoordinator`.
- Per-Invocation drain hook: when in `:processing` and the next handler call would be a new completable command, suspend with the previously-accumulated completion-ids instead.
- An integration test that stops the supervisor mid-invocation and asserts the response is a clean Suspension, not an Error.

This is the most *visibly* BEAM-flavored demo and worth investing in early in v0.2.

### Demo 4 — High-concurrency fan-out ✓ (v0.2)

> Shipped — see [docs/demo-4-fan-out.md](./docs/demo-4-fan-out.md). **Measured: 20,000 in-flight Restate invocations on a single elixir-handler pod, +1 MB peak memory over baseline, 2,489 leaves/sec sustained.** Awakeable-based gather: 1,000 children + aggregation in 1.86 s. The original plan is preserved below for context.


**Real-world pain.** "Our enrichment workflow hits 50 downstream services per request and we can't run more than ~200 concurrent without the pod OOMing." This is the canonical Node.js memory story — 1,000 in-flight Promises, each retaining a closure scope, balloons heap into the GB range. Java with `CompletableFuture` is similar; Python `asyncio` better but still dwarfs BEAM.

**The demo.** One handler that fans out to 1,000 sub-invocations (`ctx.call`) in parallel via `Task.async_stream`, gathers, and returns. Run 50 of these *concurrently* on a pod with a 256MB memory limit. Plot heap usage and P99 fan-out latency over the run. The numbers are the asset: "256MB pod, 50,000 in-flight Restate invocations, P99 fan-out roundtrip = X ms."

For comparison, the same pattern on TS on the same pod size — expect either OOM or `Promise.all` of 50,000 hitting a memory wall.

**Why BEAM specifically.** ~2KB per process baseline heap, per-process generational GC (no shared heap pressure), preemptive scheduling so one slow sub-call doesn't block the others. Go is the only competitive runtime here on raw concurrency — goroutines are similarly cheap — but Restate's per-invocation model maps more naturally onto BEAM processes than goroutines (each invocation is a process tree with a clean failure boundary, vs a `goroutine` that needs explicit `defer/recover`).

**Cost / dependencies.** Low-to-medium implementation cost — the handler is a few dozen lines. **Hard dependency on `ctx.call` support**, which is post-v0.1 (out-of-scope per the MVP scope). Don't ship Demo 4 until the SDK has `CallCommandMessage` + `CallCompletionNotificationMessage` wired up. v0.2 candidate.

### Demo 5 — Sustained-load soak ✓ (v0.2 baseline)

> Proof-of-concept baseline shipped — see [docs/demo-5-sustained-load.md](./docs/demo-5-sustained-load.md). **Measured: 2,396 `count` + 600 `long_greet` (10 s) at 50 RPS for 60 s; P50 in a 1.4 ms window, P99 drift 0.73×, peak memory delta +1 MB.** Script parameterises to the full 500 RPS × 24 h soak — that run is still ahead. The original plan is preserved below for context.


**Real-world pain.** "Latency was fine for the first hour, then degraded." Java/HotSpot G1 GC pauses widen under sustained allocation churn. V8 in Node has heap-fragmentation behavior under steady load. Ops teams budget for restarts every N hours as a workaround — which means the workflow runtime is restart-tolerant by necessity, not by design.

**The demo.** 24-hour load test, constant 500 RPS of mixed `long_greet` + `count` invocations on a single 3-pod cluster. Plot P50 / P99 / P999 latency in 1-minute buckets across the full 24 hours. Plot per-pod heap and GC pause distributions.

The thesis the graph defends: BEAM's per-process GC means there is no stop-the-world. Every flat line is a piece of evidence. Compared with a Java SDK on the same workload (canonical G1 sawtooth pause distribution) the comparison is striking.

**Why BEAM specifically.** Each BEAM process has its own heap; GC is per-process and generational. There is no global heap to compact. A pod hosting 50,000 small invocation processes is doing 50,000 independent micro-GCs spread across schedulers, never coordinated, never pausing the world. Java/Go/.NET all share a global heap and pay the coordination cost.

**Cost / dependencies.** Low to write, expensive to run (needs sustained load infrastructure for 24h, Prometheus retention, Grafana dashboards). The point of this demo is that nothing dramatic happens — its asset is the **absence** of sawtooth on the latency graph. Best shipped after Demo 2 has established the methodology.

### Suggested asset bundle for the Ewen conversation

The Week 4 outreach should lead with:

1. **Demo 1** (pod-kill, recorded) — credibility check on protocol conformance.
2. **Demo 2** (noisy-neighbor, recorded + plot) — the first BEAM-differentiated asset.

Demos 3–5 become the README's "why Elixir specifically" section and the v0.2 commitments. They're load-bearing for the upstream-absorption pitch — Stephan needs reasons to maintain another SDK beyond polyglot enablement, and "BEAM is operationally well-suited to Restate's workload shape, here are four scenarios with numbers" is a defensible one.

Sequencing for v0.2 (executed in this order): Demo 2 → Demo 3 → Demo 4 → Demo 5. All four shipped; full 500 RPS × 24 h soak run for Demo 5 is still ahead but the methodology and 60 s baseline are in place.

## Known risks

1. **Bandit HTTP/2 full-duplex streaming** was the single biggest unknown. Plug's model is request-then-response; Restate assumes interleaved frames on one stream. Outcome: the **REQUEST_RESPONSE fallback** was taken and shipped — the discovery manifest advertises it, every conformance scenario passes against it, and it costs one extra round-trip per suspension vs same-stream resume. Same-stream HTTP/2 streaming remains the v0.3 carryover; the SDK is structured so it's an incremental change in `Restate.Server.Endpoint`, not a rewrite.
2. **V5 Command/Notification correlation.** V5 splits each suspending operation into a `*CommandMessage` (with a `completion_id`) and a `*CompletionNotificationMessage` (carrying the same id). The state machine must thread completion-ids through replay; off-by-one or mis-matched ids are the new flavor of suspension bug. Watch this carefully in Week 3.
3. **Suspension semantics subtlety.** "When to suspend" (no more work to do *and* waiting on an uncompleted completable entry) has edge cases that look fine until a crash-recovery test fails. The `sdk-test-suite` is the safety net — run it early in Week 4.
4. **NIF shortcut temptation.** Wrapping `sdk-shared-core` via Rustler would be ~1–2 weeks but NIF panics crash the BEAM scheduler — directly contradicts the "BEAM-native durability" story that justifies the SDK existing. Off the table for v0.1; revisit as a production-hardening option only once the pure-Elixir SDK exists.

## License

MIT — matching Restate's official SDKs (`sdk-java`, `sdk-python`, `sdk-typescript`, `sdk-go` are all MIT-licensed).
