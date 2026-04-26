# Java SDK comparison

A component-by-component side-by-side of `restate-elixir` against
[`restatedev/sdk-java`](https://github.com/restatedev/sdk-java) — the
canonical port target per [PLAN.md](../PLAN.md). Java is the only
official Restate SDK with a pure-language state machine (the Rust /
TypeScript / Python / Go SDKs all wrap a shared Rust core via WASM,
PyO3, or cdylib bindings). Reading it line by line is the only way to
write a faithful Elixir port; this doc records what that read found.

> Java repo state: shallow clone of `main` at the time of writing
> (matches v5/v6 protocol surface). Files referenced are at
> `sdk-core/src/main/java/dev/restate/sdk/core/`.

## Headline numbers

| | Elixir | Java |
|---|---|---|
| State machine LoC | 329 (`Invocation.ex`) | 4,178 (`statemachine/` — 30 files) |
| Total SDK LoC, non-generated | 845 across 11 files | 6,648 across 44 files (`sdk-core/`) |
| Type ID registry | 80 (`Messages.ex`) | 361 (`MessageType.java`) |
| Wire framer | 83 (`Framer.ex`) | 191 (`MessageEncoder` + `MessageDecoder`) |
| User-facing Context API | 75 (`Context.ex`) | ~534 (`HandlerContextImpl.java`, partial slice) |

The headline ratio is **~8× smaller in Elixir** at the state machine
layer, but the feature surfaces aren't identical — Java has `ctx.call`,
`ctx.run`, awakeables, signals, promises, lazy state, workflow
lifecycle, retry policies, and cancellation, all of which are out of
scope for v0.1. A fair feature-matched comparison would put the Java
state-machine equivalent at perhaps 1,500–2,000 LoC. Even normalized,
the Elixir version is meaningfully smaller — for reasons that are
about idiom fit, not about incomplete work.

## Architectural divergences

The single biggest divergence drives most of the LoC gap. Worth
calling out before the per-component reads.

### Streaming reactive (Java) vs request/response (Elixir)

`StateMachineImpl extends Flow.Processor<Slice, Slice>` —
[Reactive Streams](https://www.reactive-streams.org/). Bytes arrive
slowly from the runtime via HTTP/2; the SDK buffers them, decodes one
frame at a time, dispatches asynchronously, and writes responses back
on the same stream as they're produced. This permits the
*same-stream resume* optimization — the runtime can complete a sleep
mid-handler-execution by sending a Notification on the open stream,
and the handler resumes without a new HTTP request.

`Restate.Server.Endpoint` — Plug request handler. Read the entire
body, decode all frames at once, run the handler synchronously,
write the entire response. This is the Restate
`REQUEST_RESPONSE` protocol mode — the manifest at
`apps/restate_server/lib/restate/server/manifest.ex` advertises it
explicitly. We give up same-stream resume; we get to skip the entire
streaming-decoder + buffering + backpressure layer.

What this costs us:

- Each Sleep means one full HTTP round-trip per resume, instead of a
  single long-lived stream. For a 10s sleep that's negligible
  (the runtime already waits 10s); for sub-second sleeps in tight
  loops, it adds latency.
- The MessageDecoder in Java has its own internal state machine
  (`WAITING_HEADER` / `WAITING_PAYLOAD` / `FAILED` — see
  `MessageDecoder.java:21`) to handle partial-byte input. We don't
  need it because Bandit/Plug delivers the body whole.

What it buys us:

- `MessageEncoder.java` + `MessageDecoder.java` (191 LoC) collapse to
  `Framer.ex` (83 LoC). The framer is a pure pair of functions, not
  a stateful class.
- The state machine doesn't need WaitingStartState +
  WaitingReplayEntriesState (Java has both — see
  [State.java:28-33](https://github.com/restatedev/sdk-java/blob/main/sdk-core/src/main/java/dev/restate/sdk/core/statemachine/State.java#L28))
  because we only enter init/0 once we already have all the input.
- No Reactive Streams plumbing: no `Subscriber`, no `Publisher`, no
  `Subscription`, no demand signaling.

PLAN.md flags this as the largest known risk (full-duplex HTTP/2 on
Bandit). The decision to ship REQUEST_RESPONSE for v0.1 is documented
there; this is the architectural cost.

### One process per invocation (Elixir) vs one Flow.Processor per invocation (Java)

`Restate.Server.Invocation` is a `GenServer` started per HTTP request
by [`Endpoint`'s `POST /invoke/:service/:handler`](../apps/restate_server/lib/restate/server/endpoint.ex#L38)
clause, with a linked `spawn_link`'d handler process inside `init/1`.
Two processes per invocation, both lightweight (~2KB heap each,
BEAM-managed).

Java's `StateMachineImpl` is a single object instance per invocation,
serving as both the state-machine driver and the Flow.Processor for
the input/output streams. The user handler runs on a thread pool
managed by Vert.x or the lambda runtime. Higher per-invocation
memory footprint and shared thread pool contention.

This is a real BEAM idiom: per-invocation isolation by default, no
shared scheduler state, supervisor restarts a single bad invocation
without touching the others. PLAN.md's Demo 2 (noisy neighbor) is
specifically designed to surface this.

### Sealed-interface state pattern (Java) vs flag-in-struct (Elixir)

Java models the state machine via a sealed interface
`State permits ClosedState, ProcessingState, ReplayingState,
WaitingReplayEntriesState, WaitingStartState`
([State.java:28-33](https://github.com/restatedev/sdk-java/blob/main/sdk-core/src/main/java/dev/restate/sdk/core/statemachine/State.java#L28)).
Each state is its own class with default-throw stubs for transitions
the state doesn't support — `processStateGetCommand` throws
`ProtocolException.badState(this)` unless the state overrides it.

Elixir collapses this to `state.phase ∈ {:replaying, :processing}`
plus a `:result_body` sentinel on the GenServer state map. "Bad state"
is automatic — the `case state.phase do` clauses in `handle_call/3`
either match or hit `FunctionClauseError`, which the GenServer
catches and emits as `ErrorMessage`. Three states (Java's Waiting…
two) collapse into init/0; ClosedState collapses into `{:stop,
:normal, ...}`.

The Java approach is more verbose but localizes each state's
behavior in one file. The Elixir approach is more compact because
pattern matching on the phase atom is structurally equivalent to
dispatching on the state class — without the class.

## Component-by-component

### Type ID registry

| | Elixir | Java |
|---|---|---|
| File | [`apps/restate_protocol/lib/restate/protocol/messages.ex`](../apps/restate_protocol/lib/restate/protocol/messages.ex) | [`MessageType.java`](https://github.com/restatedev/sdk-java/blob/main/sdk-core/src/main/java/dev/restate/sdk/core/statemachine/MessageType.java) |
| LoC | 80 | 361 |
| Approach | `%{type_id => protobuf_module}` literal map + reverse | enum + 4 switch statements (`encode`, `decode`, `fromMessage`, `messageParser`) + 2 predicate switches (`isCommand`, `isNotification`) |

Java needs an explicit `enum MessageType` with 36 variants because
Java's reflection + protobuf-Java's API design forces the per-message
dispatch into separate switches. In Elixir, every protobuf message
*is* its own module (`Pb.SetStateCommandMessage` etc.), so the literal
map gives bidirectional dispatch for free, and `isCommand` is
trivially reducible to a struct-module pattern match.

We deliberately match Java's type IDs verbatim (`MessageType.java:56-92`).
Cross-checked against the proto's inline `Type:` comments. Two values
are slightly fishy in the proto comments themselves and the registry
reflects the canonical Java values:

- `SendSignalCommandMessage = 0x0410` (proto comment has a stray `0`:
  it reads `0x04000 + 10`)
- `SignalNotificationMessage = 0xFBFF` (one below the custom-entry
  range starting at `0xFC00`)

### Wire framing

| | Elixir | Java |
|---|---|---|
| Files | [`Framer.ex`](../apps/restate_protocol/lib/restate/protocol/framer.ex) (83) + [`Frame.ex`](../apps/restate_protocol/lib/restate/protocol/frame.ex) (19) | `MessageEncoder.java` (61) + `MessageDecoder.java` (130) + `MessageHeader.java` |
| Approach | Pure functions: `encode/2`, `decode/1`, `decode_all/1` | Stateful classes; `MessageDecoder` has its own FSM (`WAITING_HEADER`/`WAITING_PAYLOAD`/`FAILED`) for byte-level streaming |
| Header bits | Type + Flags + Length parsed; flags stored on `Frame.flags` but not acted on | Identical: `MessageHeader.parse` stores flags as `int`, no `requiresAck()` / `completed()` accessor |

The framing logic itself is identical (8-byte header: 16-bit type +
16-bit flags + 32-bit length, big-endian). What differs is the
input model — Java buffers byte-stream input until enough is
available to parse a header, then enough for a body, then loops.
Elixir's `Framer.decode_all/1` takes a complete binary and walks it
in one pass.

**Originally flagged as a gap; corrected on second read.** The
`COMPLETED` bit (mask `0x0001` in the 16-bit flags field, or
`0x0000_0001_0000_0000` in the 8-byte header) is documented in
`service-invocation-protocol.md` as part of the V1–V4 inline-
completion model. V5's design split commands and notifications into
separate messages, so no V5 SDK uses the flag at decode time —
verified by inspection of Java's `MessageHeader.parse` and a grep
across the entire statemachine module. Storing the flags field
unused matches Java exactly. Worth keeping in mind for any future
multi-protocol-version SDK; not a v0.1 gap.

### State machine FSM

| | Elixir | Java |
|---|---|---|
| Files | [`Invocation.ex`](../apps/restate_server/lib/restate/server/invocation.ex) (329) | `StateMachineImpl.java` (677) + 5 state classes (1,237 combined) + `StateContext`, `Journal`, `EntryHeaderChecker`, etc. |
| States | `phase ∈ {:replaying, :processing}` + finalization sentinel | `WaitingStartState`, `WaitingReplayEntriesState`, `ReplayingState`, `ProcessingState`, `ClosedState` |
| Bad-state handling | Function-clause match → caught by GenServer → emitted as ErrorMessage | Each state overrides specific methods; defaults throw `ProtocolException.badState(this)` |
| Replay matching | Pop next recorded command from a queue; type-check via pattern match on struct module | Java has explicit `EntryHeaderChecker` (124 LoC) plus per-command inspection in `ReplayingState.processCompletableCommand` |

The two-state collapse (`:replaying` vs `:processing`) is exactly
right for the Restate protocol — the spec only ever distinguishes
those two phases (`service-invocation-protocol.md` lines 57–63). The
extra Java states are artifacts of streaming I/O: WaitingStart waits
for the StartMessage frame to arrive across bytes; WaitingReplay
waits for all replay entries to arrive after the InputCommand. In our
read-the-body-once model, both phases collapse into init/0 once we
already know the full replay journal.

[`Invocation.ex` lines 149–183](../apps/restate_server/lib/restate/server/invocation.ex#L149)
(the sleep handler) are roughly equivalent in structure to Java's
`ReplayingState.processCompletableCommand` +
`ProcessingState.processCompletableCommand` — pop a recorded command
(or emit a fresh one), check / allocate a completion id, suspend if
needed.

### Journal and completion-id allocation

| | Elixir | Java |
|---|---|---|
| Allocator | `starting_completion_id/1`: scan for max completion_id seen, +1. Allocated lazily in `:processing`. | `Journal.completionIndex` counter, starts at `1`, `++` per allocation. Tracked alongside `commandIndex`, `notificationIndex`, `signalIndex`. |
| Signal ID space | not implemented | Separate counter starting at `17` ("1 to 16 are reserved!" — comment in `Journal.java:24-27`) |
| Indexes maintained | none — we just have a queue of recorded commands and a notification map | command index, notification index, completion index, signal index, current entry name + type |

This was the area of highest concern before reading Java — I worried
the `max+1` allocator would diverge from a sequential counter under
concurrent commands or after replay. After reading
[Journal.java](https://github.com/restatedev/sdk-java/blob/main/sdk-core/src/main/java/dev/restate/sdk/core/statemachine/Journal.java),
the two allocators are equivalent in the SDK's code-determinism
contract: handler code is replayed identically, so the Nth completion
allocated has the same id on every replay. Both 1-based. The Elixir
allocator is doing in O(N) per allocation what Java does in O(1) —
fine for handlers with O(10) suspending operations, becomes a
micro-optimization opportunity beyond that.

**Gap surfaced:** signal IDs reserve 1–16 in Java. We don't have
signals yet (post-v0.1), but when we add them, the allocator must
start at 17 to be conformant. Document this in the source when we
add `SendSignalCommandMessage` support.

The richer indexes Java tracks (commandIndex, currentEntryTy/Name)
are used to populate `ErrorMessage.related_command_*` fields — which
Restate uses to give better debugging output when a journal mismatch
occurs. We don't populate these; we should when we hit
`pop_recorded!/2` mismatch (currently raises `RuntimeError` instead
of emitting `ErrorMessage{code: 570}` — a real fix-able gap).

### Notifications / async results

| | Elixir | Java |
|---|---|---|
| File | inline in `Invocation.ex` (`partition_journal/1`, `notification_result/1` — ~30 LoC of inline helpers) | [`AsyncResultsState.java`](https://github.com/restatedev/sdk-java/blob/main/sdk-core/src/main/java/dev/restate/sdk/core/statemachine/AsyncResultsState.java) (131 LoC) |
| Storage | `%{completion_id => result}` flat map; result is `:void` for sleep, `value` for typed | Map of notification_id → handle + queue of pending notifications + per-handle completion futures |

Our model handles the cases we need: Sleep, lazy-state-completion (we
don't emit it but partition it defensively), Call, Run. Java does
more bookkeeping because it supports out-of-order async results,
multi-await combinators (`Promise.any`/`Promise.all`-style), and
the run-with-retry-policy machinery.

When we add `ctx.call` and `ctx.run` (v0.1), the partition logic
expands modestly. When we add awaitable combinators (v0.2 — Demo 4
needs them), we'll be in roughly the same complexity territory as
`AsyncResultsState`.

### Error model

| | Elixir | Java |
|---|---|---|
| Terminal failure path | `Restate.TerminalError` raise → `OutputCommandMessage{failure: Failure{code, message, metadata}}` + `EndMessage` | `TerminalException` throw → `writeOutput(TerminalException)` → same wire frames |
| Retryable failure path | Any other raise → `ErrorMessage{code:500, message, stacktrace}` | Any other Throwable → `State.hitError` → `ErrorMessage{code, message, stacktrace, related_command_*}` |
| Journal mismatch | `pop_recorded!/2` raises `RuntimeError` → caught by exception path → emits as code 500 | `ProtocolException` with code 570 → `hitError` populates `related_command_*` for runtime introspection |

Our error model gets the high-order semantics right
(terminal-vs-retryable maps to `OutputCommandMessage{failure}` vs
`ErrorMessage`), and the conformance suite's UserErrors class
validated 6/10 cases passing. The remaining gap is two pieces:

1. **Code 570 / JOURNAL_MISMATCH semantics.** Java's
   `ProtocolException` (177 LoC, `sdk-core/.../ProtocolException.java`)
   defines specific codes — `570` for journal mismatch and `571` for
   protocol violation. Restate uses these to distinguish "your code
   diverged from the journal" (don't retry forever) from generic
   handler failures (retry per policy). Currently when we detect a
   journal mismatch (e.g. handler issued set_state but the recorded
   journal has SleepCommand at that position) we crash with a generic
   `RuntimeError` at code 500 — which Restate would interpret as a
   normal retryable error. **This is fix-able and worth fixing
   before claiming full v0.1.**

2. **`related_command_*` fields on ErrorMessage.** Java populates
   these from the Journal's tracked currentEntry. Restate uses them
   for debugging output. Cosmetic but cheap.

### User-facing Context API

| | Elixir | Java |
|---|---|---|
| File | [`Context.ex`](../apps/restate_server/lib/restate/context.ex) (75) | `HandlerContextImpl.java` (534) + `sdk-api/.../Context.java` (interface) + Kotlin coroutine wrappers |
| Style | `Restate.Context.set_state(ctx, key, value)` — synchronous `GenServer.call` per operation | `ctx.set("key", value)` — coroutine-aware, returns `Awaitable<T>` for completable ops |

The Java context surface is structurally larger because:

- Each completable operation returns an `Awaitable<T>` that's combinable
  with `Awaitable.any()` / `Awaitable.all()` — true parallel waiting.
  We don't have this yet (Sleep returns `:ok` synchronously; the
  conformance suite's `Sleep.manySleeps` test passes anyway because
  it only asserts on elapsed-time minimums).
- Java has separate ergonomic wrappers for Kotlin coroutines,
  workflow-specific contexts, and shared-context (`@Shared`)
  read-only operations.
- Type-safe state keys via `StateKey<T>` (`stateKey<Long>("counter")`)
  vs our string keys + JSON encode/decode in the SDK.

For v0.1 the Elixir surface is right-sized; the parallel-await
combinator is the v0.2 ergonomic gap we'd most miss.

### Service registration & manifest

| | Elixir | Java |
|---|---|---|
| Files | [`Registry.ex`](../apps/restate_server/lib/restate/server/registry.ex) (58) + [`Manifest.ex`](../apps/restate_server/lib/restate/server/manifest.ex) (49) | `EndpointManifest.java` (307) + `DiscoveryProtocol.java` (177) |
| Approach | `:persistent_term`-backed list of service maps; each app calls `Registry.register_service/1` from its Application | Annotation processor scans `@Service` / `@VirtualObject` / `@Workflow` at compile time; runtime endpoint binds instances |
| Manifest schema | hand-built map → `Jason.encode!` | annotation-derived; full schema validation |

Java's manifest builder is heavier because it derives the schema
from annotations including handler input/output types via reflection.
Our builder takes the registration map at face value and emits a
minimal manifest that conforms to
`apps/restate_protocol/proto/endpoint_manifest_schema.json`.
Conformance has verified our manifest is sufficient — Restate's
ingress correctly routes calls to the right handlers based on it.
The schema-validation Java does is for catching SDK-user mistakes at
build time; in Elixir those mistakes surface at registration / first
discovery.

## Things we deliberately diverged on

These are intentional design choices, not gaps.

1. **REQUEST_RESPONSE protocol mode.** Documented in
   [PLAN.md known risks](../PLAN.md#known-risks) as the deferral of
   Bandit HTTP/2 full-duplex streaming. Trade-off: each suspending
   operation costs an extra HTTP round-trip; we keep the SDK simple.

2. **Eager state only.** The `lazy-state` test suite tag is skipped.
   We use `StartMessage.state_map` for all reads. For the demo
   surface and the Counter test class this is sufficient. Lazy state
   becomes necessary when per-invocation state exceeds the eager
   bundle threshold (typically MB-scale single state values).

3. **JSON-only payloads.** Our SDK assumes handler I/O is JSON. The
   `@Raw` handler annotation in the Java contract (`TestUtilsService.rawEcho`)
   would need separate plumbing. Out of v0.1.

4. **Synchronous `Context.sleep/2`.** No Awaitable type. The
   `manySleeps` conformance test passes with sequential
   implementation; combinator support arrives with v0.2.

## Things to fix based on the read

Four fix-able gaps surfaced. None are blocking the conformance
results we already have, but each is a plausible source of "the
runtime treated my error in an unexpected way" surprises. **All four
have now been landed** (commit history starting with the one that
adds this section).

1. **Journal-mismatch → `ErrorMessage{code: 570}`.** Previously
   `pop_recorded!/2` in `Invocation.ex` raised `RuntimeError`, which
   became `ErrorMessage{code: 500}` — making Restate retry on what
   should be a non-retryable journal divergence. Now wraps in
   `Restate.ProtocolError` and routes to `ErrorMessage{code: 570}`
   (JOURNAL_MISMATCH per `service-invocation-protocol.md`).

2. **`related_command_index` / `_name` / `_type` on ErrorMessage.**
   Restate's UI uses these for debugging output. The Invocation now
   tracks `current_command_index` + `current_command_name` +
   `current_command_type` as it processes each command (replay or
   fresh emit), and populates the related_command fields when
   emitting `ErrorMessage`.

3. **Completion-ID allocator: switched from scan to counter.**
   Replaced the O(N) `max(seen completion_id) + 1` scan with a
   counter field initialized from the journal's last seen + 1,
   incremented on allocation. Matches Java's `Journal.completionIndex`
   exactly. Same correctness; cleaner code; O(1) per allocation.

4. **Signal IDs reserved 1–16 (post-v0.1 marker).** When
   `SendSignalCommandMessage` support lands, the signal allocator
   must start at 17 per `Journal.java:27`. Documented in the source
   so it's not lost.

## v0.2 work surfaced by the read

Beyond what PLAN.md already lists, these are additional v0.2 items
the Java read makes concrete:

- **Awaitable combinators** (`Awaitable.any`, `Awaitable.all`).
  Implementation in Java spans `AsyncResults.java` (353 LoC) +
  parts of `AsyncResultsState.java`. In Elixir this maps naturally
  onto a `Task.async_stream`-style API; Demo 4
  ([PLAN.md](../PLAN.md#demos-beyond-the-mvp--making-the-beam-case))
  depends on it.
- **`ctx.run` retry policies.** Java's `RunState.java` (70 LoC) +
  `proposeRunCompletion` paths handle exponential backoff,
  max-attempts, terminal-on-exhaust. Demo 5 (sustained-load soak)
  exercises this indirectly.
- **Cancellation signal (`cancelInvocation`).** Java has signal IDs
  1–16 reserved with the cancel signal at a fixed slot.
- **Workflow service type.** PLAN.md scopes this out; Java's
  `BlockAndWaitWorkflow` shows the lifecycle expectations.

## What this comparison is for

Two purposes:

1. **Internal: catch design mistakes early.** The five "things to
   fix" above are real gaps that conformance hasn't exercised yet
   but that a careful reviewer (or Stephan Ewen) would find on
   inspection. Better to fix them before the outreach than after.

2. **External: signal that the port is informed, not improvised.**
   When the conversation begins with "we built an Elixir SDK," the
   immediate question is *did you read sdk-java first?* This doc
   answers yes, with file paths.
