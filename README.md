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

> Restate persists state across pod restarts: `kubectl delete pod -l
> app=elixir-handler` and re-curl — the counter keeps incrementing from
> wherever it left off. Suspending mid-invocation across pod kills lands
> in Week 3.

In production, prefer the official Helm chart (`helm install restate
restate/restate`) over the bundled `k8s/restate.yaml`; the local manifest
is a single-node `emptyDir` setup intended only for the demo.

## Status at a glance

| Area | State |
|---|---|
| Protocol framing | ✓ encode/decode + 11 unit tests |
| Discovery manifest | ✓ `GET /discover` (REQUEST_RESPONSE, V5) |
| Context API (`get_state` / `set_state`) | ✓ eager state |
| Context API (`sleep` / `call` / `awakeable` / `run`) | — |
| Example handler (`Greeter` counter Virtual Object) | ✓ persists across pod restarts |
| `docker-compose` dev loop | ✓ against `restate:1.6.2` |
| `kind` cluster test bed | ✓ self-contained manifests in `k8s/` |
| Full `:gen_statem` replay/processing FSM | — (Week 3) |
| Conformance against `sdk-test-suite` | — |
| Durability demo (pod kill mid-sleep) | — |

Check back in ~4 weeks for the first end-to-end durability demo.

## License

MIT — matching Restate's official SDKs (`sdk-java`, `sdk-python`, `sdk-typescript`, `sdk-go` are all MIT-licensed). See [LICENSE](./LICENSE).
