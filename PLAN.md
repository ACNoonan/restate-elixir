# Plan — restate-elixir MVP

Week-by-week engineering plan for the initial 4-week MVP. Scope deliberately narrow. This document is the canonical engineering plan; deeper strategic context lives in the project's Obsidian vault notes.

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

### Out (deferred to v0.2+)

- **Workflow** service type — lifecycle and versioning complexity make this the biggest scope-risk; worth shipping a clean service-handler SDK first
- Lambda transport
- V6 protocol (superset of V5; advertise V5 only for now)
- Lazy state (`GetLazyStateCommandMessage` + completion notification round-trip) — eager covers the counter demo; lazy is needed for state larger than the eager bundle threshold
- Production hardening (observability, backpressure tuning, graceful shutdown edge cases)

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

### Week 2 — State primitives + first `kind` deploy

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

## Known risks

1. **Bandit HTTP/2 full-duplex streaming** is the single biggest unknown. Plug's model is request-then-response; Restate assumes interleaved frames on one stream. Fallback: **request/response mode** — works for the Week 3 demo (sleep suspension + re-invocation); loses the same-stream suspend/resume optimization. **Don't spend >3 days fighting Bandit before considering the fallback.** Week 1 manifest already advertises `REQUEST_RESPONSE`, so the fallback is the default unless a deliberate upgrade happens later.
2. **V5 Command/Notification correlation.** V5 splits each suspending operation into a `*CommandMessage` (with a `completion_id`) and a `*CompletionNotificationMessage` (carrying the same id). The state machine must thread completion-ids through replay; off-by-one or mis-matched ids are the new flavor of suspension bug. Watch this carefully in Week 3.
3. **Suspension semantics subtlety.** "When to suspend" (no more work to do *and* waiting on an uncompleted completable entry) has edge cases that look fine until a crash-recovery test fails. The `sdk-test-suite` is the safety net — run it early in Week 4.
4. **NIF shortcut temptation.** Wrapping `sdk-shared-core` via Rustler would be ~1–2 weeks but NIF panics crash the BEAM scheduler — directly contradicts the "BEAM-native durability" story that justifies the SDK existing. Off the table for v0.1; revisit as a production-hardening option only once the pure-Elixir SDK exists.

## License

MIT — matching Restate's official SDKs (`sdk-java`, `sdk-python`, `sdk-typescript`, `sdk-go` are all MIT-licensed).
