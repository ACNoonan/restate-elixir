# Known risks

The four open technical risks behind the SDK's design choices. Useful
context if you're reading the state machine, framer, or endpoint code,
or evaluating where the SDK is most likely to drift if not maintained.

## 1. Bandit HTTP/2 full-duplex streaming

Plug's model is request-then-response; Restate's bidirectional
protocol assumes interleaved frames on one stream. The
**REQUEST_RESPONSE fallback** was taken and shipped — the discovery
manifest advertises it, every conformance scenario passes against it,
and it costs one extra HTTP round-trip per suspension vs. same-stream
resume. Same-stream HTTP/2 streaming remains the v0.3 carryover; the
SDK is structured so it's an incremental change in
`Restate.Server.Endpoint`, not a rewrite.

## 2. V5 Command/Notification correlation

V5 splits each suspending operation into a `*CommandMessage` (carrying
a `completion_id`) and a `*CompletionNotificationMessage` (carrying
the same id). The state machine threads completion-ids through replay
in `Restate.Server.Invocation`; off-by-one or mismatched ids are the
new flavor of suspension bug introduced by V5 (V4 used a single
journaled entry per operation). Any change to how completions are
allocated or matched needs to be checked against the
`alwaysSuspending` conformance suite — `Sleep.manySleeps` (50 × 20 =
1,000 suspension cycles) is the most thorough exerciser.

## 3. Suspension semantics subtlety

"When to suspend" — no more work to do *and* waiting on an
uncompleted completable entry — has edge cases that look fine until a
crash-recovery test fails. Adding new awaitable shapes (e.g. when
landing same-stream HTTP/2 in v0.3) is the most likely place to
introduce regressions here. The `sdk-test-suite` is the safety net;
run the targeted suites before any release that touches the
`:replaying` ↔ `:processing` transitions or the `SuspensionMessage`
emit logic.

## 4. NIF shortcut temptation

Wrapping `sdk-shared-core` (Rust) via Rustler would be ~1–2 weeks of
work and would deliver the same protocol surface, but **NIF panics
crash the BEAM scheduler** — directly contradicts the BEAM-native
durability story that justifies the SDK existing as a separate
implementation rather than a wrapper. The pure-Elixir SDK has been
proven viable (49/49 conformance, Demos 1–5 shipped); NIF integration
is therefore off the table. The only place it remains worth
revisiting is for performance-critical inner loops (e.g. protobuf
encode/decode) once profiling identifies them as bottlenecks — and
even there, dirty-CPU NIFs with strict input validation, not the
shared-core wholesale.
