# restate-elixir

Elixir SDK for [Restate](https://restate.dev) — a durable execution runtime.

> **Status: pre-alpha, active development.** Greenfield project started 2026-04-24. Targeting Restate service protocol V5 (current; verified against `restate-server` 1.6.2). 13 official `sdk-test-suite` conformance tests passing; 0 SDK bugs surfaced so far. No Hex release yet.

## Why this exists

Restate ships official SDKs for TypeScript, Java, Kotlin, Python, Go, and Rust — but not Elixir. The BEAM's native primitives (processes, OTP supervision, `:gen_statem`, preemptive scheduling) are arguably the best-fit mainstream runtime for Restate's journal-replay semantics. This project aims to prove that with working code rather than theory.

Independent validation of the thesis: in February 2026, George Guimarães (Plataformatec alumni) wrote: *"A proper Temporal equivalent for Elixir. The community knows this, and it's probably the biggest gap in Elixir's agentic story right now. Elixir is better suited for building one than Python."* The gap is publicly acknowledged.

## Target user

Teams **already running Restate services** in TypeScript, Java, or Go who want to add Elixir handlers into a polyglot estate. This is not an attempt to win the Elixir-greenfield durable-workflow market against Oban or native alternatives — that's a crowded lane. The value here is making Elixir a first-class citizen of polyglot Restate deployments, which nobody else offers.

## What's in scope for the MVP

- Restate service protocol **V5** (current; ~37 message types across control / Command / Notification namespaces)
- **Service** type (stateless handlers)
- **Virtual Object** type (keyed stateful handlers with serialized concurrency per key)
- Journaled primitives implemented: `get_state` (eager), `set_state`, `clear_state`, `sleep`
- Journaled primitives planned for v0.1: `call`, `run`, `awakeable`
- HTTP/2 endpoint via Bandit (REQUEST_RESPONSE protocol mode)
- Discovery manifest at `GET /discover`
- Terminal-vs-retryable error distinction (`Restate.TerminalError` → `OutputCommandMessage{failure}`; ordinary raise → `ErrorMessage{500}` → runtime retries)
- Conformance subset from [restatedev/sdk-test-suite](https://github.com/restatedev/sdk-test-suite) — see [Conformance status](#conformance-status)
- Local K8s (`kind`) as the durability test bed

**Explicitly deferred** to v0.2+: **Workflow** service type (lifecycle + versioning complexity), V6 protocol, Lambda transport, lazy state, full HTTP/2 streaming, production hardening, the four demos that surface BEAM-specific operational properties (see [PLAN.md](./PLAN.md#demos-beyond-the-mvp--making-the-beam-case)).

See [PLAN.md](./PLAN.md) for the week-by-week scope and [PLAN.md#known-risks](./PLAN.md#known-risks) for the open technical risks.

## Quickstart

### docker-compose

Requires Docker and the `restate` CLI.

```sh
docker compose up -d                                     # restate 1.6.2 + elixir handler
restate --yes deployments register http://elixir-handler:9080
curl -sS -X POST http://localhost:8080/Greeter/world/count \
  -H 'content-type: application/json' -d 'null'
# → "hello 1"  (run again → "hello 2", state lives in Restate)
```

### kind (single-node K8s)

Requires `docker`, `kind`, `kubectl`, and the `restate` CLI.

```sh
# 1. Build and load the handler image into the kind node
docker compose build elixir-handler
docker tag restate-elixir-elixir-handler:latest restate-elixir-handler:0.1.0
kind create cluster --name restate-elixir --config k8s/kind-config.yaml
kind load docker-image restate-elixir-handler:0.1.0 --name restate-elixir

# 2. Deploy restate-server, the handler, and run the registration Job
kubectl apply -f k8s/restate.yaml
kubectl rollout status statefulset/restate -n restate
kubectl apply -f k8s/elixir-handler.yaml
kubectl rollout status deployment/elixir-handler
kubectl apply -f k8s/register.yaml
kubectl wait --for=condition=complete --timeout=60s job/register-elixir-handler

# 3. Invoke (NodePort 30080 maps to host :8080 via the kind config)
curl -sS -X POST http://localhost:8080/Greeter/world/count \
  -H 'content-type: application/json' -d 'null'
# → "hello 1"
```

In production, prefer the official Helm chart (`helm install restate
restate/restate`) over the bundled `k8s/restate.yaml`; the local manifest
is a single-node `emptyDir` setup intended only for the demo.

### The durability demo — pod kill mid-sleep

The handler at `apps/restate_example_greeter/lib/restate/example/greeter.ex` exposes a `long_greet/2` that records a step, sleeps 10s, records another step, and returns. The middle of that 10s window is where Kubernetes' chaos lives:

```sh
# In one terminal — synchronous invocation; ingress holds the connection
curl -sS -X POST http://localhost:8080/Greeter/world/long_greet \
  -H 'content-type: application/json' -d '"world"'

# In another terminal, while the handler is sleeping (~3s in)
kubectl delete pod -l app=elixir-handler --force --grace-period=0
```

The pod that started the invocation is force-deleted. Kubernetes spawns a new one — fresh BEAM, no in-memory state, no idea this invocation existed. After the original 10s timer fires, Restate re-invokes the new pod. Our SDK replays the journal, runs the post-sleep code, and returns `"hello world"`. The held curl connection from the ingress side never noticed.

```sh
restate kv get Greeter world
#  KEY   VALUE
#  step  "after_sleep"   ← post-sleep SetState committed
```

The same demo runs in `docker compose` via `docker compose kill -s SIGKILL elixir-handler && docker compose start elixir-handler` mid-sleep.

## Implementation status

| Area | State |
|---|---|
| Protocol framing (encode/decode, V5 type registry) | ✓ |
| Discovery manifest at `GET /discover` (REQUEST_RESPONSE, V5) | ✓ |
| `Restate.Context.get_state` / `set_state` / `clear_state` | ✓ (eager) |
| `Restate.Context.sleep` + `SuspensionMessage` + journal replay | ✓ |
| `Restate.Context.key/1` (per-VirtualObject path segment) | ✓ |
| `Restate.TerminalError` → `OutputCommandMessage{failure}` with metadata | ✓ |
| Non-terminal raise → `ErrorMessage{500}` → runtime retry | ✓ |
| Journal-aware Invocation `:replaying` / `:processing` state machine | ✓ |
| Example handler (`Greeter` counter + `long_greet` durability demo) | ✓ |
| `docker compose` dev loop against `restate:1.6.2` | ✓ |
| `kind` cluster test bed with self-contained manifests | ✓ |
| `Restate.Context.call` (Call command + completion notification) | — v0.1 |
| `Restate.Context.run` (Run command + result notification) | — v0.1 |
| `Restate.Context.awakeable` (promise from external completion) | — v0.1 |
| Lazy state (`GetLazyStateCommandMessage`) | — v0.2 |
| Full HTTP/2 same-stream suspend/resume | — v0.2 |
| Workflow service type | — v0.2 |
| Graceful drain on `SIGTERM` (Demo 3 in [PLAN.md](./PLAN.md#demos-beyond-the-mvp--making-the-beam-case)) | — v0.2 |

## Conformance status

Run against [`restatedev/sdk-test-suite` v4.1](https://github.com/restatedev/sdk-test-suite/releases/tag/v4.1) (the official Restate conformance harness, also used by the Java/TS/Python/Go SDKs in CI).

| Test class (suite: `alwaysSuspending`) | Result | Notes |
|---|---|---|
| `State.add` | ✅ | Counter VirtualObject — sequential `add(N)` round-trips, state persists |
| `State.proxyOneWayAdd` | ❌ | needs `ctx.call` (v0.1 work) |
| `State.listStateAndClearAll` | ❌ | needs `MapObject` + state-keys |
| `Sleep.sleep` | ✅ | basic suspend/resume |
| `Sleep.manySleeps` | ✅ | **50 invocations × 20 sleeps each** = 1,000 total, each one a full suspension cycle |
| `SleepWithFailures.sleepAndTerminateServiceEndpoint` | ✅ | service container `SIGTERM` mid-sleep |
| `SleepWithFailures.sleepAndKillServiceEndpoint` | ✅ | service container `SIGKILL` mid-sleep |
| `KillRuntime.startAndKillRuntimeRetainsTheState` | ✅ | `restate-server` container `SIGKILL` between calls |
| `StopRuntime.startAndStopRuntimeRetainsTheState` | ✅ | `restate-server` container `SIGTERM` between calls |
| `UserErrors.invokeTerminallyFailingCall` | ✅ | terminal failure surfaces with message |
| `UserErrors.invokeTerminallyFailingCallWithMetadata` | ✅ | terminal failure with `Map<String,String>` metadata |
| `UserErrors.failSeveralTimes(WithMetadata)` (×2) | ✅ | endpoint stays healthy across repeated failures |
| `UserErrors.setStateThenFailShouldPersistState` | ✅ | state-mutating commands committed before terminal failure |
| `UserErrors.invocationWithEventualSuccess` | ✅ | retry behavior on non-terminal exceptions |
| `UserErrors.internalCallFailurePropagation(WithMetadata)` (×2) | ❌ | needs `ctx.call` |
| `UserErrors.sideEffectWithTerminalError(WithMetadata)` (×2) | ❌ | needs `ctx.run` |

**13 / 19 attempted, 0 SDK bugs found.** Every red maps to a known-scope gap (`ctx.call`, `ctx.run`, lazy state, or a v0.2 service contract), not an SDK defect.

The four cells of the durability matrix are all green:

```
                    SIGTERM             SIGKILL
service container   ✅ Sleep…Terminate   ✅ Sleep…Kill
restate runtime     ✅ StopRuntime       ✅ KillRuntime
```

Reproduce locally: build the conformance image, then run the harness in `run` mode.

```sh
docker build -t localhost/restate-elixir-handler:0.1.0 .
java -jar restate-sdk-test-suite.jar run \
  --test-suite=alwaysSuspending \
  --image-pull-policy=CACHED \
  localhost/restate-elixir-handler:0.1.0
```

For iterative SDK development without rebuilding the image:

```sh
cd apps/restate_test_services && mix run --no-halt    # local SDK on :9080
java -jar restate-sdk-test-suite.jar debug \
  --test-suite=alwaysSuspending --test-name=State 9080
```

## Further reading

- [PLAN.md](./PLAN.md) — week-by-week scope, demo roadmap (Demos 2–5 making the BEAM case), known risks
- [docs/demo-2-noisy-neighbor.md](./docs/demo-2-noisy-neighbor.md) — first BEAM-differentiated asset. **P99 of the light cohort inflates to 1.53× under 10 saturating-CPU poisoned handlers; P50 stays at 0.99×.** A single-event-loop runtime would block for the full 5-second poisoning window (~25× P99 inflation, predicted).
- [docs/demo-3-graceful-drain.md](./docs/demo-3-graceful-drain.md) — `SIGTERM`-driven graceful drain. The SDK traps `SIGTERM`, lets every in-flight invocation finish, then exits. **20/20 in-flight `slow_op` invocations completed during a mid-flight drain, in the original 3 s budget, no retries.** ~150 LoC of `System.trap_signal/2` + `Process.monitor` + named-`:ets`-table; the BEAM gives us primitives Node.js / Java / Go have to build by hand.
- [docs/java-sdk-comparison.md](./docs/java-sdk-comparison.md) — component-by-component side-by-side against `restatedev/sdk-java`, the canonical port target. The Java state machine is the only pure-language Restate SDK; reading it line by line is the only way to write a faithful Elixir port. This doc records what that read found, including four concrete fix-able gaps the read surfaced (all subsequently landed).

## License

MIT — matching Restate's official SDKs (`sdk-java`, `sdk-python`, `sdk-typescript`, `sdk-go` are all MIT-licensed). See [LICENSE](./LICENSE).
