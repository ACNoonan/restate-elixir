# Changelog

All notable changes to `restate-elixir` are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`:telemetry` events** — five span / point events emitted by the
  invocation lifecycle: `[:restate, :invocation, :start | :stop |
  :exception | :replay_complete | :journal_mismatch]`. `:start` /
  `:stop` are wrapped via `:telemetry.span` and carry `service`,
  `handler`, `outcome`, `response_bytes`, and `duration`.
  `:replay_complete` fires once per resumed invocation when the
  handler catches up to live processing. `:journal_mismatch` fires
  on protocol code 570 — indicates a determinism bug, surface it.
  See `Restate.Telemetry` for the full event surface and metadata
  table. Plug into PromEx / `telemetry_metrics_prometheus` /
  `opentelemetry_telemetry` with one `:telemetry.attach_many` call
  at app boot.
- **`Restate.RequestIdentity` + `Restate.Plug.RequestIdentity`** —
  Ed25519 JWT verification for `restate-server` requests, wire-
  compatible with the Java SDK's `sdk-request-identity`. Reads
  `:request_identity_keys` from the `:restate_server` app env at
  request time (auto-installed in `Restate.Server.Endpoint`); no-op
  when unconfigured so dev / docker-compose loops keep working.
  Path filter defaults to `/invoke/*` so `/discover` stays
  unsigned. Multiple keys supported for rolling rotation. Pure
  Erlang `:crypto` verification — no JWT library dependency. Vendored
  Base58 decoder matches the Bitcoin alphabet used by Restate's
  `publickeyv1_*` key format.
- **`Restate.Test.FakeRuntime.run/3`** — in-memory test runtime
  for handlers. Drives a handler all the way to its terminal
  outcome by spawning the SDK's `Invocation` GenServer, watching
  what it emits, and synthesising the completion notifications
  a real `restate-server` would deliver. Auto-completes sleeps
  (instant `:void`), `ctx.run` (uses the SDK's proposed value),
  and lazy state reads (served from the initial `:state` opt).
  `ctx.call` requires a per-target mock via `:call_responses`.
  Awakeables and workflow promises raise with helpful messages
  (v0 scope). Returns a result struct with the terminal outcome,
  decoded value, derived final state, full journal transcript,
  and a `run_completions` map for downstream tooling.
- **`Restate.Test.CrashInjection.assert_replay_determinism/3`** —
  exhaustive prefix-replay test harness covering both Restate
  correctness properties:
  * **Resumption correctness** (Property 1) — for every prefix of
    the handler's full journal, replay either suspends cleanly or
    matches the baseline outcome and value.
  * **Side-effect-once correctness** (Property 2) — for every
    prefix that contains a `ctx.run` `RunCommand`, the harness
    synthesises a matching `RunCompletionNotificationMessage`
    carrying the value the function returned in the baseline. The
    SDK MUST skip the user function and return the recorded value;
    if it doesn't, the harness raises. This is the headline
    exactly-once guarantee, tested directly.

  Baseline is now computed by delegating to `Restate.Test.FakeRuntime`,
  so the harness works on **any** handler shape — sleeps, ctx.run,
  ctx.call (with mocks), state, lazy state — not just `ctx.run`-only
  ones. Diagnostics name which branch (`:without_run_completions`
  vs `:with_run_completions`) and which prefix length tripped the
  assertion. Leans on BEAM's cheap process spawn — up to `2(n+1)`
  independent `Invocation` GenServers per call.
- `config/test.exs` binds Bandit to an OS-assigned ephemeral port so
  `mix test` doesn't collide with whatever's already on 9080
  (typical when a Restate dev container or another SDK is running).

### Changed

- `Restate.Server.Invocation.await_response/2` now returns
  `{outcome, body}` instead of just `body` — the outcome tag is the
  same one reported in `:stop` event metadata. Internal API; the
  endpoint is the only non-test caller.
- `Restate.Server.Invocation.start_link/1` takes a five-tuple
  `{start, input, journal, mfa, dispatch_meta}` instead of a four-
  tuple. `dispatch_meta` is `%{service: binary, handler: binary}`
  used as `:telemetry` metadata; pass `%{}` from non-HTTP contexts.

## [0.2.0] — 2026-04-28

**Conformance: 49 / 49 across all targeted `sdk-test-suite` v4.1
classes** in `alwaysSuspending`, `lazyState`, and
`lazyStateAlwaysSuspending`. Up from 19 / 19 in v0.1.0.

### Added

- **Cancellation** — built-in CANCEL signal (signal_id 1) detected at
  journal partition time, raised as
  `Restate.TerminalError{code: 409, message: "cancelled"}` from the
  next still-blocking Context op. `Restate.Context.cancel_invocation/2`
  emits `SendSignalCommand{idx: 1}` for handler-side cancellation. The
  SDK propagates cancel through outstanding `ctx.call`s by emitting an
  explicit `SendSignalCommand` to the callee — `restate-server` does
  not auto-cascade. Conformance: `KillInvocation` + `Cancellation × 6`.
- **Awaitable combinators** — `Restate.Awaitable.{await, any, all}/2`
  on top of new deferred-emit primitives `Restate.Context.timer/2`
  and `Restate.Context.call_async/5`. Multi-handle suspension lists
  the union of `waiting_completions` + `waiting_signals`. Conformance:
  `Combinators × 3`.
- **`ctx.run` retry policies** — `Restate.RetryPolicy` struct with
  `initial_interval_ms`, `max_interval_ms`, `factor`, `max_attempts`.
  Synchronous in-SDK retry with exponential backoff, mirroring
  `sdk-java`'s `RunState.java`. On exhaustion, propose terminal
  failure so future replays see the same error deterministically.
  Conformance: `RunRetry × 3`.
- **`ctx.run` flush** — every `ctx.run` now suspends after
  `ProposeRunCompletion` so the runtime can ack durable storage
  before the next side-effect runs. Conformance: `RunFlush.flush`.
- **Workflow service type + durable promises** —
  `Restate.Context.{get_promise, peek_promise, complete_promise, reject_promise}/2-4`.
  Workflow handler type advertised in the discovery manifest;
  one-shot-per-key idempotency is enforced by the Restate runtime.
  Conformance: `WorkflowAPI.setAndResolve`.
- **Lazy state** — SDK reads `StartMessage.partial_state` on init
  and falls back to `GetLazyStateCommand` / `GetLazyStateKeysCommand`
  for keys not bundled in the eager `state_map`. `Map.fetch/2`
  distinguishes "fetched and absent" (nil sentinel) from "not yet
  probed" (missing-from-map). Conformance: `lazyState × 3` +
  `lazyStateAlwaysSuspending × 3`.
- **Demo 5** — sustained-load soak script
  (`scripts/demo_5_sustained_load.exs`) + writeup
  (`docs/demo-5-sustained-load.md`). Short-run baseline: 2,396
  `count` completions across 60 s, P50 in a 1.4 ms envelope, peak
  memory delta +1 MB.

### Fixed

- `Context.encode_parameter`, `Proxy.result_to_binary`, and
  `encode_run_value` no longer treat Elixir strings as raw protocol
  bytes; switched to `{:raw, bytes}` explicit opt-out for callers
  who hold pre-encoded wire bytes.
- `Proxy.oneWayCall` now forwards the `delayMillis` field as
  `OneWayCallCommandMessage.invoke_time` (absolute UNIX-epoch ms).
- The `awakeable_id` wire format now uses the V5 `sign_1` prefix
  with the `(StartMessage.id, signal_id)` tuple so resolutions
  route via `OutboxMessage::NotifySignal` (verified against
  `restate-server` 1.6.2/3).
- Journal-mismatch crashes (`pop_recorded!/2`) now emit
  `ErrorMessage{code: 570, related_command_*}` instead of generic
  500s, matching the V5 spec.

### Changed

- Suspension messages now always include `signal_id 1` in
  `waiting_signals` so cancel can preempt any wait.
- The completion-id allocator uses an O(1) counter seeded from
  `max(seen) + 1` instead of an O(N) scan per allocation.

## [0.1.0] — 2026-04-24

Initial release. Greenfield project.

### Added

- Protocol V5 framing (`Restate.Protocol.{Frame, Framer, Messages}`).
- Discovery manifest at `GET /discover` (REQUEST_RESPONSE mode).
- `Restate.Server.Invocation` state machine with `:replaying` /
  `:processing` phases.
- `Restate.Context` user API: `get_state`, `set_state`, `clear_state`,
  `clear_all_state`, `state_keys`, `sleep`, `call`, `send`,
  `send_async`, `run`, `awakeable`, `complete_awakeable`,
  `reject_awakeable`, `key`.
- `Restate.TerminalError` / `Restate.ProtocolError` distinction →
  `OutputCommandMessage{failure}` vs `ErrorMessage`.
- `Restate.Server.DrainCoordinator` + SIGTERM trap.
- Bandit-served `Restate.Server.Endpoint` (Plug, REQUEST_RESPONSE).
- Examples: `Greeter` (counter + long_greet), `NoisyNeighbor`
  (Demo 2), `Drainable` (Demo 3), `Fanout` (Demo 4).
- Conformance: 19 / 19 across the targeted `alwaysSuspending`
  classes (State, Sleep, SleepWithFailures, KillRuntime, StopRuntime,
  UserErrors).

[0.2.0]: https://github.com/ACNoonan/restate-elixir/releases/tag/v0.2.0
[0.1.0]: https://github.com/ACNoonan/restate-elixir/releases/tag/v0.1.0
