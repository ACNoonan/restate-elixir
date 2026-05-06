# Gap analysis & BEAM-leverage opportunities

Working list. Two halves:

1. **Parity gaps** — things `sdk-java` ships that `restate-elixir`
   doesn't. The goal here is "match", not "innovate".
2. **BEAM-leverage opportunities** — places where the BEAM runtime
   (preemption, supervision, hot reload, `:telemetry`, distributed
   Erlang, macros, property testing) lets us ship something the Java
   SDK structurally can't. The goal here is "ship better, not just
   equivalent".

Companion docs:
- [java-sdk-comparison.md](./java-sdk-comparison.md) — what's already
  shipped, file-by-file.
- [known-risks.md](./known-risks.md) — open architectural risks.

---

## Part 1 — Parity gaps

### 1.1 Same-stream HTTP/2 suspend / resume

- **Java**: Vert.x Reactive Streams; suspension and resume share one
  HTTP/2 stream, full-duplex.
- **Elixir today**: Bandit Plug REQUEST_RESPONSE; one extra HTTP
  round-trip per suspension.
- **Cost**: documented in `known-risks.md §1`. Tight `sleep` loops or
  many sequential awakeables pay the round-trip per cycle.
- **Path**: `Restate.Server.Endpoint` rewrite to use Bandit's HTTP/2
  raw-stream API (or a fallback to Mint/Finch for the streaming half).
  Was carried over to v0.3.
- **Difficulty**: medium — Bandit's HTTP/2 streaming is workable but
  Plug-shaped APIs fight it.

### 1.2 Lambda transport

- **Java**: `sdk-lambda` + `BaseRestateLambdaHandler`.
- **Elixir today**: none.
- **Path**: there's an established AWS Lambda Erlang runtime
  ([aws/aws-lambda-erlang-runtime-interface-client](https://github.com/aws-samples/aws-lambda-erlang-runtime-interface-client));
  ship a `restate_lambda` app that adapts the same `Invocation`
  GenServer to a one-shot invocation model.
- **Difficulty**: medium. **Caveat**: BEAM cold-start is the issue,
  not the runtime — investigate before committing. Probably wants
  `lambda_runtime` snapshot / SnapStart equivalent (doesn't exist for
  BEAM today). May be a parity item we choose to skip and lean into
  long-running container deployments instead.

### 1.3 Request identity / JWT verification ✓ shipped

- **Java**: `sdk-request-identity` — verifies signed requests from the
  Restate server.
- **Elixir today**: nothing; trusts the network.
- **Path**: pure crypto port. `:jose` + `Plug` middleware in front of
  `Restate.Server.Endpoint`.
- **Difficulty**: low. Maybe a weekend.

**Status (unreleased):** shipped as `Restate.RequestIdentity` (pure
verifier) and `Restate.Plug.RequestIdentity` (Plug shim,
auto-installed in Endpoint). Hand-rolled — no `:jose` dep needed
since Erlang `:crypto.verify(:eddsa, ...)` handles Ed25519 directly
and JWTs are just three base64url segments. Vendored 50-line Base58
decoder matches the Bitcoin alphabet used by Restate's
`publickeyv1_*` format. 30 tests across
`apps/restate_server/test/restate/request_identity/base58_test.exs`,
`request_identity_test.exs`, and
`plug/request_identity_test.exs` cover Base58 round-trip, key parsing
errors, JWT happy/error paths (case-insensitive headers, multi-key
rotation, malformed JWT, wrong-key signature), and Plug behaviour
(no-op when unconfigured, 401 on failure, `/discover` exempt, custom
path filters).

### 1.4 Admin client

- **Java**: OAS-generated client for the `restate-server` admin API
  (deployments, invocation queries, service registration).
- **Elixir today**: users hand-roll HTTP calls.
- **Path**: generate from the same OpenAPI spec via
  [`open_api_spex`](https://hex.pm/packages/open_api_spex) or hand-write a
  thin `Req`-based client. See **§2.4** below for the BEAM-native
  version of this same idea.
- **Difficulty**: low (boring port) → medium if we go the §2.4 route.

### 1.5 Fake API for offline testing ✓ shipped

- **Java**: `sdk-fake-api` lets unit tests drive a handler without a
  live `restate-server`.
- **Elixir today**: tests require a live server (we run it in
  `docker-compose`).
- **Path**: an in-memory journal harness that feeds messages directly
  into `Restate.Server.Invocation` and asserts on emitted commands.
  Most of the plumbing is already there in the conformance harness.
- **Difficulty**: low. High value for users writing handlers.

**Status (unreleased):** shipped as `Restate.Test.FakeRuntime.run/3`
with a `Restate.Test.FakeRuntime.Result` struct (outcome, value,
state, journal, run_completions, iterations). v0 auto-completes
sleep / `ctx.run` / lazy state; `ctx.call` requires a `:call_responses`
mock; awakeable awaits and workflow promises raise with helpful
messages — both deferred to v0.5 since they need explicit interactive
APIs (the test would have to "deliver" the awakeable value mid-run).
16 tests in `apps/restate_server/test/restate/test/fake_runtime_test.exs`
cover pure / state / sleep / lazy-state / `ctx.run` / `ctx.call`
shapes plus the helpful-error paths and the max-iterations cap.
`Restate.Test.CrashInjection.compute_baseline` was rewired to
delegate here, so the crash-injection harness now drives **any**
handler shape — not just `ctx.run`-only.

### 1.6 Codegen / ergonomic service registration

- **Java**: annotation processor (`sdk-api-gen`) generates discovery
  and dispatch from `@Service` / `@Workflow` / `@Handler`
  annotations.
- **Elixir today**: manual `Restate.Registry.register_service/1`
  calls.
- **Path**: see **§2.1** — Elixir macros are strictly more capable
  than annotations, so this should be a leverage item, not just a
  port.

### 1.7 Multiple serde backends

- **Java**: Jackson, kotlinx.serialization, plus pluggable `Serde<T>`.
- **Elixir today**: `Jason` only.
- **Path**: a `Restate.Serde` behaviour with default Jason impl;
  community can ship `Restate.Serde.Msgpack`, `Restate.Serde.Protobuf`,
  etc. Cheap.
- **Difficulty**: low. Mostly an extraction.

### 1.8 Kotlin-equivalent second-language story

- **Java**: full Kotlin codegen path (`sdk-api-kotlin-gen` via KSP),
  coroutine-flavored Context API.
- **Elixir today**: Elixir only — no Erlang surface.
- **Path**: an Erlang-callable wrapper module (`restate_sdk` in
  Erlang). The Elixir core stays as-is; we expose
  `restate_sdk:call/3`-shaped functions. Probably 200 LoC of glue.
- **Difficulty**: low if we restrict to the imperative API. Skip the
  macro-based service definitions on the Erlang side.

---

## Part 2 — BEAM-leverage opportunities

These are places where the Java SDK has a structural ceiling and we
have a structural floor. Highest value first.

### 2.1 Macro-based service definitions with compile-time validation

Java's annotation processor is a code generator constrained by Java
syntax. Elixir macros run with the AST in scope and can:

- Validate handler signatures at compile time (arity, return type,
  `Restate.Context` as first arg).
- Generate the discovery manifest entry **at compile time** from the
  module attributes — no runtime registration.
- Produce typed wrappers for `ctx.call(MyService.handler/2)` so
  callers get compile errors when a handler is renamed or removed.
- Emit `@spec`s automatically; Dialyzer then catches misuse across
  service boundaries.

Sketch:

```elixir
defmodule Greeter do
  use Restate.Service

  handler :greet, input: %{name: :string}, output: :string do
    fn ctx, %{name: name} ->
      ctx |> Restate.run("ts", fn -> DateTime.utc_now() end)
      "Hello, #{name}"
    end
  end
end
```

The `use Restate.Service` macro registers the handler, generates the
manifest entry, and emits a typed call helper. This goes meaningfully
beyond what `@Workflow` / `@Handler` can do in Java.

**Difficulty**: medium. **Differentiator**: high — this is what an
Elixir developer would expect from an SDK. The current manual
registration feels foreign.

### 2.2 `:telemetry` integration for first-class observability ✓ shipped

`:telemetry` is the BEAM-ecosystem-wide convention for emitting
events. Phoenix, Ecto, Finch, Bandit all emit them. Plugging into
Prometheus / OpenTelemetry / Datadog / Honeycomb is one library call.

Emit events for:

- `[:restate, :invocation, :start | :stop | :exception]`
- `[:restate, :invocation, :replay]` — with journal entry count
- `[:restate, :invocation, :suspend | :resume]`
- `[:restate, :run, :start | :stop | :retry]`
- `[:restate, :state, :get | :set | :clear]` — with key + lazy/eager
- `[:restate, :sleep, :requested | :elapsed]`

Java's observability story is JFR + Micrometer + manual
instrumentation; less unified, more friction. Shipping clean
`:telemetry` events out of the box is an immediate win for any team
that already runs PromEx or OpenTelemetry.

**Difficulty**: low. **Differentiator**: high — almost free, ships
alongside §2.1.

**Status (unreleased):** all five events live in `Restate.Telemetry`
and exercised by `apps/restate_server/test/restate/telemetry_test.exs`
(7 tests). `:start` / `:stop` are emitted via `:telemetry.span` from
the endpoint; `:replay_complete` fires from `advance_phase/1` when
the journal drains; `:journal_mismatch` fires from
`finalize_journal_mismatch/3` carrying `code`, `message`, and
`command_index`.

### 2.3 Crash-injection test harness ✓ shipped

The whole pitch of Restate is durability across crashes. The Elixir
SDK can prove it more honestly than Java can:

```elixir
test "handler resumes after kill mid-suspension" do
  Restate.Test.with_handler(MyService, fn pid ->
    Restate.Test.crash_after_journal_entries(pid, 3)
    # ... drive the invocation; assert the resumed run produces the
    # same output.
  end)
end
```

Implementation: spawn the `Invocation` GenServer in the test, wire a
`:telemetry` handler that calls `Process.exit(pid, :kill)` after N
journal entries, then drive a fresh invocation with the same
invocation id and assert determinism.

Java's `sdk-fake-api` can mock the wire protocol but can't cheaply
simulate "the OS killed your process mid-run". On BEAM, killing a
process is a one-line primitive.

**Difficulty**: low–medium. **Differentiator**: very high — this
makes the durability story testable, which is exactly what
prospective users want to verify before committing.

**Status (unreleased):** shipped as `Restate.Test.CrashInjection.assert_replay_determinism/3`.
Took the rigorous angle (exhaustive prefix replay over the full
emitted journal) rather than the timing-dependent `Process.exit`
flavour — every prefix is a possible mid-crash state, so iterating
all of them covers strictly more ground than killing at a single
chosen point. The harness now tests **both** Restate correctness
properties:

* **Property 1 (resumption correctness)**: every prefix replays to
  either `:suspended` or the baseline terminal.
* **Property 2 (exactly-once for `ctx.run`)**: for every prefix
  containing a `RunCommand`, the harness also runs a Branch B that
  synthesises a `RunCompletionNotificationMessage` from the
  baseline's `ProposeRun` value. The SDK must skip the user
  function and return the recorded value — directly tests the
  headline exactly-once guarantee.

Baseline is computed by looping the handler through `ctx.run`-only
suspensions until terminal or stuck on a non-`ctx.run` suspension.
10 tests in `apps/restate_server/test/restate/test/crash_injection_test.exs`
cover pure / stateful / sleeping / multi-step / `ctx.run` /
non-deterministic shapes. The Branch B assertion includes a
side-effect counter check (`assert count == 3` for a one-`ctx.run`
handler) that empirically proves the user function is not called
when completions are synthesised. The synchronous `Process.exit`
demo could still be worth shipping later as a showpiece — file as
a follow-up.

### 2.4 Admin client as a supervised, fault-tolerant pool

Instead of a thin generated HTTP client (the Java approach), ship the
admin client as a supervised tree:

- `Finch` pool for connection reuse and HTTP/2 multiplexing.
- `Fuse` (or hand-rolled) circuit breakers per Restate cluster
  endpoint.
- Retry trees with exponential backoff via `Restate.Retry` (the same
  one we already use for `ctx.run`).
- `:telemetry` events on every admin call.
- Optional `:pg`-backed cluster awareness — multiple SDK pods share a
  view of which Restate endpoints are healthy.

The Java client is `RestTemplate`-shaped — call it, catch the
exception. We can ship a client that's actually production-grade by
default.

**Difficulty**: medium. **Differentiator**: medium — most teams won't
care, but the ones that do will care a lot.

### 2.5 Property-based testing of journal replay determinism

Replay determinism is the load-bearing invariant of the whole SDK.
Java tests it with example-based unit tests. We can fuzz it:

```elixir
property "any valid command sequence replays deterministically" do
  check all sequence <- journal_sequence_generator() do
    {output1, _} = Invocation.run(sequence)
    {output2, _} = Invocation.run(sequence)
    assert output1 == output2
  end
end
```

Use `StreamData` to generate journals with shrinking. The first time
this finds a real bug, it pays for the entire investment.

**Difficulty**: medium (designing the generator is the work).
**Differentiator**: medium-high — `jqwik` exists for Java but isn't
idiomatic; in Elixir, property testing is first-class and the test
output shrinks to a minimal failing journal.

### 2.6 Hot code reload for handler updates

BEAM can replace a module's code while processes are running. For an
SDK that ships handler implementations, this means:

- Redeploy a handler bug fix without dropping in-flight invocations.
- Run two versions of a handler side-by-side during canary.

Catches: Restate's replay invariant means we **must not** hot-swap
mid-replay if the swap would change the journal sequence. The
constraint is "swap only between invocations or at safe points". This
is a correctness mine, not a free win, and needs explicit design.

**Difficulty**: high (design + safety checks). **Differentiator**:
high if we get it right. Defer to v0.4+.

### 2.7 Distributed Erlang for multi-pod SDK clusters

When multiple SDK pods serve the same Restate deployment, they could
form a BEAM cluster (`libcluster` / `:pg`) and share:

- A consensus view of which deployments are registered.
- Health and load signals.
- Coordinated graceful shutdown across pods (`DrainCoordinator` could
  go cluster-wide).

Java teams do this with external coordination (Consul, Zookeeper, k8s
endpoints). On BEAM it's a stdlib feature.

**Difficulty**: medium. **Differentiator**: low–medium — Restate
itself is the source of truth for deployments, so this would mostly
benefit operational concerns. Worth it only if we identify a concrete
problem it solves; risk of building it because we can.

### 2.8 `mix restate.gen.service` scaffolding

Elixir convention: every framework ships Mix tasks for scaffolding
(`mix phx.gen.live`, `mix ecto.gen.migration`). `mix
restate.gen.service` would generate a service module + test scaffold
+ docker-compose entry. Java has IDE plugins but no CLI scaffold.

**Difficulty**: low. **Differentiator**: low individually, but matters
for "feels native to the ecosystem".

### 2.9 Backpressure-aware batch handlers via GenStage / Flow

For handlers that fan out (`ctx.send` to N services, or stream
process), GenStage-shaped APIs give native backpressure. Java's
reactive streams are roughly comparable here, so this is more
"matched" than "advantaged" — flagging it for completeness.

**Difficulty**: medium. **Differentiator**: low — Java has equivalent
primitives.

### 2.10 `:observer`-style introspection of in-flight invocations

`:observer` can already see every `Invocation` GenServer in the
system. With a small extension (or LiveView dashboard), we could
surface the journal state of every in-flight invocation in real
time — including which completion id is blocking, how many entries
have been replayed, current state. The JVM has JMX but inspecting an
in-flight workflow's journal needs custom tooling on the Java side.

**Difficulty**: medium. **Differentiator**: high for ops/debugging
story; "open the dashboard, see your stuck workflows".

---

## Triage

Rough rank by ROI (impact ÷ effort), excluding §1.1 which is already
tagged as v0.3 carryover:

1. ~~**§2.2 `:telemetry`** — almost free, ships to every user.~~ ✓
   shipped (unreleased).
2. ~~**§2.3 crash-injection harness** — small effort, makes the
   durability pitch testable.~~ ✓ shipped (unreleased) as
   `Restate.Test.CrashInjection.assert_replay_determinism/3`.
3. ~~**§1.5 fake API** — boring port, high user value.~~ ✓ shipped
   (unreleased) as `Restate.Test.FakeRuntime.run/3`.
4. ~~**§1.3 request identity** — weekend, removes a real production
   blocker.~~ ✓ shipped (unreleased) as `Restate.RequestIdentity` +
   `Restate.Plug.RequestIdentity`.
5. **§2.1 macro-based service definitions** — bigger lift but this
   is what makes the SDK feel native.
6. **§1.7 serde extensibility** — cheap extraction, opens contribution
   surface.
7. **§2.5 property tests** — pays for itself the first time it finds
   a bug.
8. **§2.10 LiveView introspection** — flashy, helps with sales /
   demos.
9. **§1.4 admin client / §2.4 supervised pool** — depends on user
   demand.
10. **§1.2 Lambda** — investigate cold-start before committing.
11. **§2.6 hot reload / §2.7 distributed Erlang** — defer until
    concrete need.

To extend: add new items inline under the right Part, keep the triage
list at the bottom synced.
