# restate-elixir

Elixir SDK for [Restate](https://restate.dev) — a durable execution runtime.

> **Status: v0.2.0 feature-complete; pre-alpha quality.** Greenfield project started 2026-04-24. Targeting Restate service protocol V5 + V6 (verified against `restate-server` 1.6.2; runtime negotiates V6 by default, confirmed via `deployment.service_protocol_version: V6` in the partition-state-machine logs). **202 / 202 official `sdk-test-suite` conformance tests passing across all eight test suites under V6** — clean sweep including `alwaysSuspending`, `default`, `lazyState`, `lazyStateAlwaysSuspending`, `persistedTimers`, `singleThreadSinglePartition`, `threeNodes`, `threeNodesAlwaysSuspending`. `v0.2.0` git tag prepared; Hex publish pending.

## Why this exists

Restate ships official SDKs for TypeScript, Java, Kotlin, Python, Go, and Rust — but not Elixir. The BEAM's native primitives (processes, OTP supervision, `:gen_statem`, preemptive scheduling) are arguably the best-fit mainstream runtime for Restate's journal-replay semantics. This project aims to prove that with working code rather than theory.

Independent validation of the thesis: in February 2026, George Guimarães (Plataformatec alumni) wrote: *"A proper Temporal equivalent for Elixir. The community knows this, and it's probably the biggest gap in Elixir's agentic story right now. Elixir is better suited for building one than Python."* The gap is publicly acknowledged.

## Target user

Teams **already running Restate services** in TypeScript, Java, or Go who want to add Elixir handlers into a polyglot estate. This is not an attempt to win the Elixir-greenfield durable-workflow market against Oban or native alternatives — that's a crowded lane. The value here is making Elixir a first-class citizen of polyglot Restate deployments, which nobody else offers.

## What's implemented

v0.2.0 ships beyond the original MVP plan. Concretely:

- Restate service protocol **V5 + V6** (negotiated per request; ~37 message types across control / Command / Notification namespaces). V6 adds `StartMessage.random_seed` (consumed by `Restate.Context.random_uniform/1,2`, `random_bytes/2`, `random_uuid/1` for deterministic-across-replays randomness without `ctx.run`) and an official `Failure.metadata` field (already supported under V5)
- **Service**, **Virtual Object**, and **Workflow** service types
- Journaled primitives: `get_state` (eager + lazy), `set_state`, `clear_state`, `clear_all_state`, `state_keys`, `sleep`, `call`, `send` (incl. `delayMillis`), `run` (with retry policies + flush), `awakeable` + `complete_awakeable`
- Workflow durable promises: `get_promise`, `peek_promise`, `complete_promise`, `reject_promise`
- Cancellation surface (`cancel_invocation` + built-in CANCEL signal id 1) and awaitable combinators (`Awaitable.any` / `all` / `await`)
- HTTP/2 endpoint via Bandit, **REQUEST_RESPONSE** protocol mode
- Discovery manifest at `GET /discover`
- Terminal-vs-retryable error distinction (`Restate.TerminalError` → `OutputCommandMessage{failure}`; ordinary raise → `ErrorMessage{500}` → runtime retries)
- `Restate.Server.DrainCoordinator` + SIGTERM trap for graceful shutdown
- Demos 1-5 all landed — see the `docs/demo-*.md` files linked under [Further reading](#further-reading)
- 202 / 202 official `sdk-test-suite` conformance tests across all eight test suites (`alwaysSuspending`, `default`, `lazyState`, `lazyStateAlwaysSuspending`, `persistedTimers`, `singleThreadSinglePartition`, `threeNodes`, `threeNodesAlwaysSuspending`) under V6-negotiated invocations — see [Conformance status](#conformance-status)
- Local K8s (`kind`) as the durability test bed

**Carried to v0.3+**: full HTTP/2 same-stream suspend/resume (the bidirectional streaming optimisation — REQUEST_RESPONSE works in production but takes one extra round-trip per suspension), V7 protocol (Future-based `awaiting_on` and revised `SuspensionMessage`), Lambda transport, deeper production hardening (observability, backpressure tuning).

See [docs/known-risks.md](./docs/known-risks.md) for the open technical risks behind the SDK's design choices.

## Quickstart

### Add to your project (once published)

```elixir
# mix.exs
def deps do
  [
    {:restate_server, "~> 0.2"}
  ]
end
```

`restate_server` brings in `restate_protocol` transitively. The
user-facing API lives in the `Restate.*` namespace — `Restate.Context`
for handler ops, `Restate.Awaitable` for combinators,
`Restate.RetryPolicy` for `ctx.run` retry config,
`Restate.TerminalError` for business-logic failures. Register
your handlers via `Restate.Server.Registry.register_service/1`
from your application's `start/2`. The Bandit endpoint runs on
port 9080 by default.

### Run the example handler — docker-compose

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
docker tag restate-elixir-elixir-handler:latest restate-elixir-handler:0.2.0
kind create cluster --name restate-elixir --config k8s/kind-config.yaml
kind load docker-image restate-elixir-handler:0.2.0 --name restate-elixir

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
| Discovery manifest at `GET /discover` (REQUEST_RESPONSE, V5..V6) | ✓ |
| Per-request V5/V6 protocol negotiation via `content-type` (415 on out-of-range) | ✓ (unreleased) |
| Deterministic randomness (`Restate.Context.random_uniform/1,2`, `random_bytes/2`, `random_uuid/1` fed by V6 `StartMessage.random_seed`) | ✓ (unreleased) |
| `Restate.Context.get_state` / `set_state` / `clear_state` | ✓ (eager) |
| `Restate.Context.sleep` + `SuspensionMessage` + journal replay | ✓ |
| `Restate.Context.key/1` (per-VirtualObject path segment) | ✓ |
| `Restate.Context.call` + `Restate.Context.send` (Call / OneWayCall) | ✓ |
| `Restate.Context.run` (Run command + Propose / completion notification) | ✓ |
| `Restate.Context.awakeable` + `complete_awakeable` (signal-based) | ✓ |
| `Restate.TerminalError` → `OutputCommandMessage{failure}` with metadata | ✓ |
| `Restate.ProtocolError` → `ErrorMessage{code: 570/571}` (non-retryable) | ✓ |
| Non-terminal raise → `ErrorMessage{500}` → runtime retry | ✓ |
| Journal-aware Invocation `:replaying` / `:processing` state machine | ✓ |
| `Restate.Server.DrainCoordinator` + SIGTERM trap (graceful shutdown) | ✓ |
| Example handler (`Greeter` counter + `long_greet` durability demo) | ✓ |
| `NoisyNeighbor` + `Drainable` demo handlers (Demos 2 + 3) | ✓ |
| `docker compose` dev loop against `restate:1.6.2` | ✓ |
| `kind` cluster test bed with self-contained manifests | ✓ |
| Cancellation (`cancelInvocation` + built-in CANCEL signal id 1) | ✓ (v0.2) |
| Awaitable combinators (`Awaitable.any` / `Awaitable.all` / `Awaitable.await`) | ✓ (v0.2) |
| `ctx.run` retry policies (max-attempts / backoff via `Restate.RetryPolicy`) | ✓ (v0.2) |
| `ctx.run` flush (suspend-after-propose for durability) | ✓ (v0.2) |
| Workflow service type + durable promises (`get_promise` / `peek_promise` / `complete_promise` / `reject_promise`) | ✓ (v0.2) |
| Lazy state (`GetLazyStateCommandMessage` + `GetLazyStateKeysCommandMessage`, honors `StartMessage.partial_state`) | ✓ (v0.2) |
| `:telemetry` events (`[:restate, :invocation, :start \| :stop \| :exception \| :replay_complete \| :journal_mismatch]`) | ✓ (unreleased) |
| Crash-injection harness (`Restate.Test.CrashInjection.assert_replay_determinism/3`) | ✓ (unreleased) |
| In-memory test runtime (`Restate.Test.FakeRuntime.run/3`) | ✓ (unreleased) |
| Request identity verification (Ed25519 JWT, `Restate.RequestIdentity` + `Restate.Plug.RequestIdentity`) | ✓ (unreleased) |
| Static determinism Credo check (`Restate.Credo.Checks.NonDeterminism`) | ✓ (unreleased) |
| Full HTTP/2 same-stream suspend/resume | — v0.3 |
| V7 service protocol (`SuspensionMessage.awaiting_on`, `AwaitingOnMessage`, Future-based suspension) | — v0.3+ |

## Conformance status

Run against [`restatedev/sdk-test-suite` v4.1](https://github.com/restatedev/sdk-test-suite/releases/tag/v4.1) (the official Restate conformance harness, also used by the Java/TS/Python/Go SDKs in CI).

**Latest run (V6 negotiated): 202 / 202 across all eight test suites** (`alwaysSuspending` 42/42, `default` 39/39, `lazyState` 3/3, `lazyStateAlwaysSuspending` 3/3, `persistedTimers` 3/3, `singleThreadSinglePartition` 39/39, `threeNodes` 37/37, `threeNodesAlwaysSuspending` 36/36; `restate-server` 1.6.2; `service_protocol_version: V6` confirmed in the runtime's `PinnedDeployment` log). Reproduce with `elixir scripts/matrix_baseline.exs`.

**Per-test-class detail (v0.2 clean sweep across the originally-targeted classes):**

| Test class (suite) | Result | Notes |
|---|---|---|
| `State.add` (alwaysSuspending) | ✅ | Counter VirtualObject — sequential `add(N)` round-trips, state persists |
| `State.proxyOneWayAdd` (alwaysSuspending) | ✅ | exercises `ctx.send` via the Proxy service |
| `State.listStateAndClearAll` (alwaysSuspending) | ✅ | exercises `MapObject` + `clear_all_state` + `state_keys` |
| `Sleep.sleep` (alwaysSuspending) | ✅ | basic suspend/resume |
| `Sleep.manySleeps` (alwaysSuspending) | ✅ | **50 invocations × 20 sleeps each** = 1,000 total, each one a full suspension cycle |
| `SleepWithFailures.sleepAndTerminateServiceEndpoint` | ✅ | service container `SIGTERM` mid-sleep |
| `SleepWithFailures.sleepAndKillServiceEndpoint` | ✅ | service container `SIGKILL` mid-sleep |
| `KillRuntime.startAndKillRuntimeRetainsTheState` | ✅ | `restate-server` container `SIGKILL` between calls |
| `StopRuntime.startAndStopRuntimeRetainsTheState` | ✅ | `restate-server` container `SIGTERM` between calls |
| `UserErrors.invokeTerminallyFailingCall(WithMetadata)` (×2) | ✅ | terminal failure surfaces with message + `Map<String,String>` metadata |
| `UserErrors.failSeveralTimes(WithMetadata)` (×2) | ✅ | endpoint stays healthy across repeated failures |
| `UserErrors.setStateThenFailShouldPersistState` | ✅ | state-mutating commands committed before terminal failure |
| `UserErrors.invocationWithEventualSuccess` | ✅ | retry behavior on non-terminal exceptions |
| `UserErrors.internalCallFailurePropagation(WithMetadata)` (×2) | ✅ | exercises terminal-error propagation through `ctx.call` |
| `UserErrors.sideEffectWithTerminalError(WithMetadata)` (×2) | ✅ | exercises terminal failure inside `ctx.run` |
| `NonDeterminismErrors.method` (×4) | ✅ | journal-mismatch detection across `setDifferentKey`, `eitherSleepOrCall`, `callDifferentMethod`, `backgroundInvokeWithDifferentTargets` |
| `ServiceToServiceCommunication.regularCall` | ✅ | request-response `ctx.call` round-trip |
| `ServiceToServiceCommunication.callWithIdempotencyKey` | ✅ | de-duped retry via idempotency key |
| `ServiceToServiceCommunication.oneWayCall(WithIdempotencyKey)` (×2) | ✅ | fire-and-forget `ctx.send` |
| `KillInvocation.kill` (default) | ✅ **v0.2** | admin-API kill cascades through `ctx.call` chain; lock released |
| `Cancellation.cancelFromContext` × `{CALL, SLEEP, AWAKEABLE}` | ✅ **v0.2** | SDK-side `ctx.cancel_invocation` interrupts each blocking-op shape |
| `Cancellation.cancelFromAdminAPI` × `{CALL, SLEEP, AWAKEABLE}` | ✅ **v0.2** | admin-API cancel interrupts each blocking-op shape |
| `Combinators.awakeableOrTimeoutUsingAwaitAny` | ✅ **v0.2** | `Awaitable.any` over awakeable + timer; suspension lists union of waiting completions/signals |
| `Combinators.awakeableOrTimeoutUsingAwakeableTimeoutCommand` | ✅ **v0.2** | high-level "await with timeout" via `Awaitable.any` + raise on timer index |
| `Combinators.firstSuccessfulCompletedAwakeable` | ✅ **v0.2** | `awaitAnySuccessful` loop — drops failed handles, retries until one succeeds |
| `RunRetry.withSuccess` | ✅ **v0.2** | infinite-retry `ctx.run` succeeds on attempt 4 — counter reaches ≥ 3 |
| `RunRetry.executedOnlyOnce` | ✅ **v0.2** | `max_attempts: 1` exhausts immediately, terminal failure journaled |
| `RunRetry.withExhaustedAttempts` | ✅ **v0.2** | `max_attempts: 3` exhausts, terminal proposed, handler reads counter |
| `RunFlush.flush` | ✅ **v0.2** | `ctx.run` suspends after `ProposeRunCompletion`; final replay returns 0 |
| `ServiceToServiceCommunication.oneWayCallWithDelay` | ✅ **v0.2** | `delayMillis` forwarded as `OneWayCallCommandMessage.invoke_time` |
| `WorkflowAPI.setAndResolve` | ✅ **v0.2** | one-shot Workflow + durable promise round-trip (`get_promise`, `peek_promise`, `complete_promise`) |
| `State × 3` (lazyState) | ✅ **v0.2** | same handlers under `partial_state: true`; SDK lazy-fetches via `GetLazyStateCommandMessage` |
| `State × 3` (lazyStateAlwaysSuspending) | ✅ **v0.2** | lazy-state matrix with the always-suspend execution mode |

**202 / 202 across all eight test suites under V6** (clean sweep, exit 0). Notable v0.2/V6 design points surfaced by the conformance suite:
  * Cancel does not auto-cascade through `ctx.call` — the SDK emits an explicit `SendSignalCommand{idx: 1}` to the callee's invocation_id at the await site.
  * `ctx.run` retries happen synchronously inside the SDK with exponential backoff (matching `sdk-java`'s `RunState.java`); the runtime sees only the final `ProposeRunCompletion`. After exhaustion the SDK proposes a terminal failure so future replays are deterministic.
  * `ctx.run` suspends after each propose so the runtime can ack durable storage before the next side-effect runs — that's why `RunFlush` asserts the final response is 0 (every prior propose lives in the journal, none re-execute on the final replay).
  * **Discovery quiescence gate** (`Restate.Server.Registry.wait_for_quiescence/2`): `/discover` waits until the registry has been quiet for 200ms before responding, so the per-test deployer never sees a partial service list during umbrella boot. Without this, `Combinators` + `default`-suite `UserErrors` tests intermittently 404'd on services registered late in `restate_test_services.Application.start/2` — a long-standing race that V6 conformance work surfaced.

The four cells of the durability matrix are all green:

```
                    SIGTERM             SIGKILL
service container   ✅ Sleep…Terminate   ✅ Sleep…Kill
restate runtime     ✅ StopRuntime       ✅ KillRuntime
```

Reproduce locally: build the conformance image, then run the harness in `run` mode.

```sh
docker build -t localhost/restate-elixir-handler:0.2.0 .
java -jar restate-sdk-test-suite.jar run \
  --test-suite=alwaysSuspending \
  --image-pull-policy=CACHED \
  localhost/restate-elixir-handler:0.2.0
```

For iterative SDK development without rebuilding the image:

```sh
cd apps/restate_test_services && mix run --no-halt    # local SDK on :9080
java -jar restate-sdk-test-suite.jar debug \
  --test-suite=alwaysSuspending --test-name=State 9080
```

## Further reading

- [docs/known-risks.md](./docs/known-risks.md) — the four open technical risks behind the SDK's design choices (Bandit HTTP/2 fallback, V5 Command/Notification correlation, suspension semantics, NIF shortcut)
- [docs/demo-2-noisy-neighbor.md](./docs/demo-2-noisy-neighbor.md) — first BEAM-differentiated asset. **P99 of the light cohort inflates to 1.53× under 10 saturating-CPU poisoned handlers; P50 stays at 0.99×.** A single-event-loop runtime would block for the full 5-second poisoning window (~25× P99 inflation, predicted).
- [docs/demo-3-graceful-drain.md](./docs/demo-3-graceful-drain.md) — `SIGTERM`-driven graceful drain. The SDK traps `SIGTERM`, lets every in-flight invocation finish, then exits. **20/20 in-flight `slow_op` invocations completed during a mid-flight drain, in the original 3 s budget, no retries.** ~150 LoC of `System.trap_signal/2` + `Process.monitor` + named-`:ets`-table; the BEAM gives us primitives Node.js / Java / Go have to build by hand.
- [docs/demo-4-fan-out.md](./docs/demo-4-fan-out.md) — high-concurrency fan-out throughput, two shapes. **Fire-and-forget: 20,000 in-flight Restate invocations on a single elixir-handler pod, +1 MB peak memory over baseline, 2,489 leaves/sec sustained.** **Awakeable-based gather: 1,000 children fanned out + results aggregated in 1.86 s, two HTTP round-trips on the orchestrator side regardless of N.** Per-process generational GC keeps memory delta sublinear in concurrency.
- [docs/demo-5-sustained-load.md](./docs/demo-5-sustained-load.md) — sustained-load soak. **2,396 `count` invocations + 600 `long_greet` (10 s) at constant 50 RPS for 60 s; P50 stayed in a 1.4 ms window, P99 drift 0.73× (the last bucket was *faster* than the first), peak memory delta +1 MB.** The script parameterises to the PLAN's full 500 RPS × 24 h soak; per-process GC means there is no global sawtooth to find, no matter how long it runs.
- [docs/java-sdk-comparison.md](./docs/java-sdk-comparison.md) — component-by-component side-by-side against `restatedev/sdk-java`, the canonical port target. The Java state machine is the only pure-language Restate SDK; reading it line by line is the only way to write a faithful Elixir port. This doc records what that read found, including four concrete fix-able gaps the read surfaced (all subsequently landed).
- [docs/gap-analysis.md](./docs/gap-analysis.md) — working list of remaining gaps vs `sdk-java` plus BEAM-leverage opportunities (telemetry, crash-injection harness, macro-based service definitions, property-tested replay, …) ordered by ROI.

## Telemetry

The runtime emits five [`:telemetry`](https://hexdocs.pm/telemetry) events per invocation. Attach once at app boot and forward to Prometheus / OpenTelemetry / Datadog / Logger:

```elixir
:telemetry.attach_many(
  "my-app-restate",
  [
    [:restate, :invocation, :start],
    [:restate, :invocation, :stop],
    [:restate, :invocation, :exception],
    [:restate, :invocation, :replay_complete],
    [:restate, :invocation, :journal_mismatch]
  ],
  &MyApp.RestateMetrics.handle_event/4,
  nil
)
```

`:start` / `:stop` are emitted by `:telemetry.span` and carry `service`, `handler`, `outcome` (`:value | :terminal_failure | :error | :suspended | :journal_mismatch`), `response_bytes`, and a wall-clock `duration` in `:native` time units. `:replay_complete` fires once when a resumed invocation catches up to live processing, with the count of replayed commands. `:journal_mismatch` fires on protocol code 570 (handler asked for a command type the recorded journal doesn't have at that index) — surface this on a dashboard; it indicates a deterministic-replay bug. Full event surface and metadata table at `Restate.Telemetry`.

## Authentication

Restate signs requests to the SDK with an Ed25519 JWT carried in `x-restate-signature-scheme: v1` + `x-restate-jwt-v1: <jwt>` headers. The SDK verifies the signature against configured public keys; `restate-server` distributes them as `publickeyv1_<base58>` strings.

`Restate.Plug.RequestIdentity` is auto-installed in the endpoint pipeline. To enable enforcement, set `:request_identity_keys` in the `:restate_server` app environment:

```elixir
# config/runtime.exs
if keys = System.get_env("RESTATE_REQUEST_IDENTITY_KEYS") do
  config :restate_server,
    request_identity_keys: String.split(keys, ",", trim: true)
end
```

Without that config the plug is a no-op (dev / docker-compose loops keep working). When configured, `/invoke/*` requests are verified; `/discover` is intentionally excluded since Restate's discovery probe isn't signed. Multiple keys are supported for rolling rotation: list both old and new keys during cutover. Wire-compatible with the Java SDK's `sdk-request-identity`. See `Restate.RequestIdentity` for the pure verifier API if you need to verify outside a Plug pipeline.

## Offline handler testing

`Restate.Test.FakeRuntime.run/3` drives a handler all the way to its terminal outcome without a live `restate-server`, docker-compose stack, or HTTP listener. Sleep / `ctx.run` / lazy state suspensions auto-complete in-memory; `ctx.call`s use per-target mocks; awakeable / workflow-promise suspensions raise with explanations (v0 scope).

```elixir
test "Greeter increments and returns" do
  result = Restate.Test.FakeRuntime.run(
    {MyApp.Greeter, :greet, 2},
    %{"name" => "world"},
    state: %{"counter" => Jason.encode!(2)},
    call_responses: %{
      {"OtherService", "compute"} => fn _params -> 42 end
    }
  )

  assert result.outcome == :value
  assert result.value == "hello 3"
  assert result.state["counter"] == "3"
end
```

The result struct (`%Restate.Test.FakeRuntime.Result{}`) carries the terminal outcome, decoded value, derived final state map, full journal transcript, and a `run_completions` map indexed by completion id. `Restate.Test.CrashInjection` (below) uses `FakeRuntime` under the hood to drive baseline runs, so the crash-injection harness now works on any handler shape — not just `ctx.run`-only ones.

## Crash-injection testing

`Restate.Test.CrashInjection.assert_replay_determinism/3` drives your handler all the way through to its terminal outcome (looping through `ctx.run` suspensions by synthesising the runtime's completions from each iteration's `ProposeRunCompletion`), captures the full command journal, then replays against **every prefix** of that journal in two branches:

* **`:without_run_completions`** — the SDK falls back to re-executing any `ctx.run` it encounters, exercising the rare "runtime hasn't acked yet" path.
* **`:with_run_completions`** — for every `RunCommand` in the prefix, the harness synthesises a `RunCompletionNotificationMessage` carrying the value the function returned in the baseline. The SDK MUST skip the user function and return the recorded value — this is Restate's headline exactly-once guarantee, tested directly.

```elixir
test "Greeter is replay-deterministic" do
  Restate.Test.CrashInjection.assert_replay_determinism(
    {MyApp.Greeter, :greet, 2},
    %{"name" => "world"}
  )
end
```

Each prefix corresponds to a possible mid-crash state the runtime might persist before re-invoking; the harness asserts the handler either suspends cleanly or matches the baseline outcome and value. The harness leans on BEAM's cheap process spawn — up to `2(n+1)` independent `Invocation` GenServers per call, ~40 µs each. A non-deterministic handler (e.g. one that touches `:erlang.unique_integer/1` *outside* a `ctx.run`) raises with a structured diagnostic that names the failing branch, divergent prefix, expected vs. actual outcome, and decoded reply frame. See `Restate.Test.CrashInjection` for the full API and side-effect-counting semantics.

## Static determinism check

`Restate.Credo.Checks.NonDeterminism` is an opt-in [Credo](https://hex.pm/packages/credo) check that flags non-deterministic function calls in handler modules outside of a `Restate.Context.run/2,3` lambda. Replay determinism is the load-bearing invariant of the SDK; this catches the easy-mode mistakes (`DateTime.utc_now/0`, `:rand.uniform/1`, `:erlang.unique_integer/0`, `make_ref/0`, `System.os_time/0`, `Node.self/0`, …) before they ship.

```elixir
# .credo.exs
%{
  configs: [
    %{
      name: "default",
      checks: %{
        extra: [
          {Restate.Credo.Checks.NonDeterminism, []}
        ]
      }
    }
  ]
}
```

Only files that reference `Restate.Context` are scanned, so adding the check to a polyglot Elixir codebase doesn't drown unrelated modules in warnings. Pass `excluded_modules: [MyApp.Helper]` to silence the check on a specific module. Crash-injection covers the runtime side; this covers the static side. See `Restate.Credo.Checks.NonDeterminism` for the full forbidden-MFA list and the documented limitations (helper modules, captured-fn args).

## License

MIT — matching Restate's official SDKs (`sdk-java`, `sdk-python`, `sdk-typescript`, `sdk-go` are all MIT-licensed). See [LICENSE](./LICENSE).
