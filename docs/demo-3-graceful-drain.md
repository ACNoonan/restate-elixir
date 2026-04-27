# Demo 3 — Graceful drain on `SIGTERM`

The most visibly BEAM-flavored demo. Every Kubernetes operator has
been bitten by `kubectl drain` truncating in-flight requests; this
shows the SDK trapping `SIGTERM`, waiting for the in-flight cohort to
complete, *then* exiting.

## The scenario

A handler pod is serving N concurrent invocations, each ~3 seconds
of work. Kubernetes (or `docker compose` for the demo) sends
`SIGTERM` partway through — the standard signal for "wrap it up,
you've got `terminationGracePeriodSeconds` to finish."

| Without drain | With drain |
|---|---|
| BEAM hard-exits on `SIGTERM`. In-flight invocations die mid-handler. Restate sees connection drops, retries each on another pod (or this pod after restart). Visible disruption + retry storm. | SDK traps `SIGTERM`, broadcasts drain, waits for in-flight invocations to finish, then `System.stop`. Endpoint returns `503` to *new* POSTs during the drain window so Restate routes them elsewhere. Zero dropped work. |

## Implementation — three pieces, ~150 LoC

**1. [`Restate.Server.DrainCoordinator`](../apps/restate_server/lib/restate/server/drain_coordinator.ex)**
 — GenServer that owns a named `:ets` table for the drain bit
 (lock-free hot-path read) plus a `Process.monitor`-tracked map of
 in-flight Invocation pids. `drain/1` flips the bit, blocks on every
 monitored pid going `:DOWN`, returns `{:ok, %{remaining: n}}`. With
 grace expiry, returns whatever's left.

**2. [`Restate.Server.Application`](../apps/restate_server/lib/restate/server/application.ex)**
 — adds `DrainCoordinator` to the supervisor and registers a
 `System.trap_signal(:sigterm, …)` handler that calls
 `DrainCoordinator.drain(25_000)` then `System.stop(0)`. ~30 LoC.

**3. [`Restate.Server.Endpoint`](../apps/restate_server/lib/restate/server/endpoint.ex)**
 — every `POST /invoke/:service/:handler` first reads
 `DrainCoordinator.draining?/0` (single ETS lookup, nanoseconds).
 If true: `503 retry-after: 1`. Restate's ingress retries on another
 pod. ~5 LoC of change.

`Invocation.init/1` registers itself with the coordinator on creation
(one line). When the GenServer terminates — naturally on success, or
via the linked Endpoint process dying — the monitor fires and the
coordinator drops it from the set.

## Measured run

```
$ docker compose up -d
$ restate --yes deployments register http://elixir-handler:9080 --use-http1.1
$ elixir scripts/demo_3_graceful_drain.exs
```

On a 10-core MacBook against `restate:1.6.2`, with 20 concurrent
`NoisyNeighbor.slow_op` invocations (each: state write → 3 s
`:timer.sleep` → state write → return):

```
=== Demo 3 — graceful drain on SIGTERM ===
ingress       : http://localhost:8080
in-flight     : 20  (concurrent slow_op calls, ~3s each)
SIGTERM after : 1000ms

--- T+0    : firing 20 concurrent slow_op invocations ---
--- T+1001ms : sending SIGTERM ---
Container restate-elixir-elixir-handler-1 Killing
 Container restate-elixir-elixir-handler-1 Killed
--- waiting for invocations to drain ---

--- results ---
  total wall-clock  : 3.03s
  success           : 20 / 20
  failed            : 0

  per-call duration:
    P50 / P99 / max : 3.02s / 3.03s / 3.03s

✓ All in-flight invocations completed gracefully.
```

Container logs show the trace from the SDK side:

```
00:24:09.544 [info] SIGTERM received — draining (grace 25000ms)
00:24:11.324 [info] Sent 200 in 3001ms        × 20  ← all 20 invocations
00:24:11.327 [info] Drain complete — all invocations finished gracefully
00:24:11.327 [notice] SIGTERM received - shutting down  ← OTP's BEAM exit
```

The container is gone after the run — `docker compose ps elixir-handler`
shows no row. Restate is still up; the next `docker compose up -d`
brings the handler back.

## Why BEAM specifically

Three primitives compose naturally for this:

**`System.trap_signal/2`** — Elixir 1.12+. Lets us replace the
default `SIGTERM` handler with arbitrary code. The trap function
runs in its own process; from there we can call into application
state, wait on supervised processes, and explicitly `System.stop(0)`
when we're ready.

**`Process.monitor/1`** — bidirectional: the coordinator gets a
`:DOWN` message when an Invocation exits for *any* reason, including
the linked Plug request handler dying first. We don't need
`trap_exit` (no link soup); we don't need cooperative checkin/checkout
from the Invocation side. Just `register(self())` once on creation;
the monitor handles the rest.

**Lightweight processes + supervisor model** — every Restate
invocation already runs in its own process tree. Tracking "what's
in flight" is just a map of pids; no shared event loop, no thread
pool to drain, no cooperative-cancellation token to plumb through
every codepath.

The whole DrainCoordinator is **141 LoC** of pure Elixir. The
trap handler is **30 LoC** in the Application. The Endpoint hook
is **5 LoC**. Total ~150 LoC for "wait for in-flight requests to
finish on `SIGTERM`."

## What a Node.js / Python / Java handler would need

**Node.js** — no built-in primitive. You'd register
`process.on('SIGTERM', …)` then hand-wire shutdown coordination
across every handler module: a global "draining" flag, every async
operation checking it, a counter of in-flight requests, manually
preventing new connections via `server.close()`. Easy to get wrong
(missed code paths, forgotten timer / interval handles keeping the
process alive, request bodies still streaming when `server.close`
is called). No supervisor concept; failure of the drain coordinator
itself takes down the whole process.

**Java** — `Runtime.addShutdownHook`. Then a thread-pool flush
dance: `pool.shutdown()`, `pool.awaitTermination(grace, …)`,
`pool.shutdownNow()` if the timeout expires. Per-thread cleanup logic
for any non-pool work. Servlet containers (Tomcat, Jetty) provide
their own shutdown lifecycle that interacts with the JVM hook.

**Go** — manual `context.Context` propagation through every handler,
`signal.Notify` to receive `SIGTERM`, a wait group for in-flight
requests, careful goroutine lifecycle. Closer to the BEAM model than
Java/Node, but every handler must explicitly check
`ctx.Done()` and exit on cancellation; no preemption.

The BEAM version isn't shorter because we cut corners — it's shorter
because the runtime gives us the primitives the others have to build
by hand.

## Tests

[`apps/restate_server/test/restate/server/drain_coordinator_test.exs`](../apps/restate_server/test/restate/server/drain_coordinator_test.exs):

- `draining?/0` is `false` until `drain/1` is called
- `drain/1` returns immediately with no in-flight invocations
- `drain/1` waits for registered invocations to terminate, then
  returns; doesn't over-wait
- `drain/1` honours `grace_ms` when invocations don't finish in time
  (returns with `remaining: n > 0`)
- `register/1` is a no-op when the coordinator isn't running
  (graceful degradation in tests / minimal deployments)
- registered processes auto-deregister on exit via `Process.monitor`

7 tests, all passing.

## Reproduce locally

```sh
# 1. Bring up a fresh stack with the drain plumbing
docker compose up -d --build
restate --yes deployments register http://elixir-handler:9080 --use-http1.1

# 2. Run the harness — fires 20 concurrent slow_op + sends SIGTERM
elixir scripts/demo_3_graceful_drain.exs

# 3. Inspect the SDK-side trace
docker compose logs elixir-handler | grep -E 'SIGTERM|drain|Drain'
```

Knobs (env vars):

```
IN_FLIGHT      concurrent slow_op invocations            (default: 20)
SIGTERM_AFTER  ms after start before SIGTERM             (default: 1000)
INGRESS        Restate ingress URL                        (default: http://localhost:8080)
COMPOSE_SVC    docker compose service to SIGTERM          (default: elixir-handler)
```

`docker-compose.yml` sets `stop_grace_period: 30s` so compose
doesn't escalate to `SIGKILL` while drain is still running. The
SDK's drain grace is 25 s; compose has 5 s of headroom on top.

## Follow-ups

1. **Demo 3 in `kind`** — the same scenario but `kubectl drain
   <node>` instead of `docker compose kill`. Multiple handler pods,
   verify Restate routes the displaced traffic to surviving pods.
   Asset: a side-by-side timeline (without-trap pod drops X% of
   in-flight; with-trap drops 0%).
2. **`Restate.Context.draining?/1`** — let user handlers query the
   drain state from inside long-running work and choose to exit
   early via `Restate.Context.suspend/1` (a v0.2 API). Useful for
   workflows that want to checkpoint at a clean boundary rather than
   block the drain window.
3. **Endpoint readiness probe** — surface `draining?/0` via
   `GET /readyz` so Kubernetes' load balancer drops the pod from
   the service endpoint as soon as drain begins, even before
   `terminationGracePeriodSeconds` expires. Reduces the "request
   arrives 100ms after SIGTERM, sees 503" race window.
