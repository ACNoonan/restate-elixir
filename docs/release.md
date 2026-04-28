# Release process

Two Hex packages are published from this repo:

  * **`restate_protocol`** (`apps/restate_protocol`) — the protocol
    layer (V5 framing + generated protobuf modules + the upstream
    `protocol.proto`). Consumers don't usually depend on this
    directly; it's pulled in transitively by `restate_server`.
  * **`restate_server`** (`apps/restate_server`) — the user-facing
    SDK (`Restate.Context`, `Restate.Awaitable`, `Restate.RetryPolicy`,
    the `Restate.Server.*` runtime, `Restate.TerminalError`).

The umbrella also contains `restate_example_greeter` and
`restate_test_services` — these are for development and conformance
testing and **are not published**.

## Versioning

Both publishable packages move in lock-step. On each release, bump
`@version` in:

  * Top-level [`mix.exs`](../mix.exs)
  * [`apps/restate_protocol/mix.exs`](../apps/restate_protocol/mix.exs)
  * [`apps/restate_server/mix.exs`](../apps/restate_server/mix.exs)

`restate_server` declares its dependency on `restate_protocol` with
the same version constraint, so a published `restate_server v0.2.0`
pulls in `restate_protocol ~> 0.2.0`.

## Pre-release checklist

1. **Tests green.** `mix test` from the umbrella root must pass —
   currently 80 + 1 doctest.
2. **Conformance green.** Build the docker image and run the
   targeted suites:
   ```sh
   docker build -t localhost/restate-elixir-handler:0.2.0 .
   java -jar restate-sdk-test-suite.jar run \
     --test-suite=alwaysSuspending \
     --image-pull-policy=CACHED \
     localhost/restate-elixir-handler:0.2.0
   ```
   Plus `lazyState`, `lazyStateAlwaysSuspending`, and
   `--test-name=KillInvocation` against `default`. Currently
   49/49 across all targeted classes.
3. **`CHANGELOG.md` updated** with the new version's notable
   changes — additions, fixes, breaking changes if any.
4. **Versions bumped** in all three `mix.exs` files.
5. **Dry-run hex.build** for both apps (see below) and confirm the
   files list matches what should ship.

## Dry-run

```sh
# Protocol package
cd apps/restate_protocol
mix hex.build
# inspect the .tar — should contain lib/, proto/, mix.exs, README.md,
# LICENSE, CHANGELOG.md
rm restate_protocol-*.tar

# Server package — must set RESTATE_HEX_PUBLISH so the protocol dep
# resolves to a hex version constraint (the in_umbrella sibling
# is unpublishable)
cd ../restate_server
RESTATE_HEX_PUBLISH=1 mix hex.build
rm restate_server-*.tar
```

The `RESTATE_HEX_PUBLISH` flag is what makes
`apps/restate_server/mix.exs` declare `{:restate_protocol, "~> X.Y.Z"}`
instead of `{:restate_protocol, in_umbrella: true}`. The flag exists
specifically because the publish needs a hex-resolvable dep, while
day-to-day `mix test` needs the umbrella sibling.

## Publish

Publish `restate_protocol` **first** so `restate_server`'s dep
resolves on the public registry.

```sh
# From the repo root
mix hex.user whoami   # confirm you're logged in

# 1. Protocol — pure-data package, no umbrella shenanigans needed
cd apps/restate_protocol
mix hex.publish

# 2. Server — needs the env flag for the dep declaration
cd ../restate_server
RESTATE_HEX_PUBLISH=1 mix hex.publish
```

Hex prompts for confirmation and shows the file list both times.

## After publish

1. **Tag the release.**
   ```sh
   cd ../..   # back to repo root
   git tag -a v0.2.0 -m "v0.2.0"
   git push origin v0.2.0
   ```
2. **Create a GitHub release** from the tag with a copy of the
   relevant `CHANGELOG.md` section as the body.
3. **Announce** in any community channels (elixirforum.com tag
   "restate", Restate Discord, etc.).

## Future: rename to `:restate`

The current OTP app is `:restate_server`, which means consumers
write `{:restate_server, "~> 0.2"}`. Cleaner would be a single
top-level `:restate` app — verbose otp/app names tend to age badly.
A v0.3 rename is the natural time to do this. It needs:

  * Move `apps/restate_server` → `apps/restate` (or flatten the
    umbrella entirely).
  * Update `application: [mod: ...]` to `Restate.Application`.
  * Update the manifest's discovery endpoint module references.
  * Coordinate the package name on hex.pm — at v0.3 this is a
    small migration; later it gets harder.

Until then, `restate_server` is the published name. The `Restate.*`
module namespace stays stable across the rename either way.
