# restate-elixir

Elixir SDK for [Restate](https://restate.dev) — a durable execution runtime.

> **Status: pre-alpha, active development.** Greenfield project started 2026-04-24. Targeting Restate service protocol V5 (current; works against `restate-server` 1.6.2). No Hex release yet.

## Why this exists

Restate ships official SDKs for TypeScript, Java, Kotlin, Python, Go, and Rust — but not Elixir. The BEAM's native primitives (processes, OTP supervision, `:gen_statem`, preemptive scheduling) are arguably the best-fit mainstream runtime for Restate's journal-replay semantics. This project aims to prove that with working code rather than theory.

Independent validation of the thesis: in February 2026, George Guimarães (Plataformatec alumni) wrote: *"A proper Temporal equivalent for Elixir. The community knows this, and it's probably the biggest gap in Elixir's agentic story right now. Elixir is better suited for building one than Python."* The gap is publicly acknowledged.

## Target user

Teams **already running Restate services** in TypeScript, Java, or Go who want to add Elixir handlers into a polyglot estate. This is not an attempt to win the Elixir-greenfield durable-workflow market against Oban or native alternatives — that's a crowded lane. The value here is making Elixir a first-class citizen of polyglot Restate deployments, which nobody else offers.

## What's in scope for the MVP

- Restate service protocol **V5** (current; ~37 message types across control / Command / Notification namespaces)
- **Service** type (stateless handlers)
- **Virtual Object** type (keyed stateful handlers with serialized concurrency per key)
- Journaled primitives: `get_state` (eager), `set_state`, `sleep`, `call`, `run`, `awakeable`
- HTTP/2 endpoint via Bandit
- Discovery manifest at `GET /discover`
- Conformance subset from [restatedev/sdk-test-suite](https://github.com/restatedev/sdk-test-suite)
- Local K8s (`kind`) as the durability test bed

**Explicitly deferred** to v0.2+: **Workflow** service type (lifecycle + versioning complexity), V6 protocol, Lambda transport, lazy state, production hardening.

See [PLAN.md](./PLAN.md) for the week-by-week scope.

## Quickstart

Requires Docker and the `restate` CLI.

```sh
docker compose up -d                                     # restate 1.6.2 + elixir handler
restate --yes deployments register http://elixir-handler:9080
curl -sS -X POST http://localhost:8080/Greeter/greet \
  -H 'content-type: application/json' -d '"world"'
# → "hello"
```

## Status at a glance

| Area | State |
|---|---|
| Protocol framing | ✓ encode/decode + 11 unit tests |
| Discovery manifest | ✓ `GET /discover` (REQUEST_RESPONSE, V3) |
| State machine (`:gen_statem`) | — |
| Context API (`get_state`/`set_state`/`sleep`/...) | — |
| Example handler (`Greeter`) | ✓ non-durable echo |
| `docker-compose` dev loop | ✓ against `restate:1.6.2` |
| `kind` cluster test bed | — |
| Conformance against `sdk-test-suite` | — |
| Durability demo (pod kill mid-sleep) | — |

Check back in ~4 weeks for the first end-to-end durability demo.

## License

MIT — matching Restate's official SDKs (`sdk-java`, `sdk-python`, `sdk-typescript`, `sdk-go` are all MIT-licensed). See [LICENSE](./LICENSE).
