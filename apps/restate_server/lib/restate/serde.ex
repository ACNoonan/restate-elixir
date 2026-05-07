defmodule Restate.Serde do
  @moduledoc """
  Pluggable serialization for handler I/O, state values, `ctx.run`
  results, `ctx.call` parameters, and awakeable payloads.

  ## Default

  The default impl is `Restate.Serde.Json` (Jason-backed). It matches
  the wire format every other Restate SDK speaks, so a polyglot
  Restate deployment with TS / Java / Python / Go services
  interoperates with this SDK out of the box without any opt-in.

  ## Switching globally

  Set the `:serde` key in the `:restate_server` app environment:

      config :restate_server, :serde, MyApp.Restate.Serde.Msgpack

  Anything implementing the `Restate.Serde` behaviour (two callbacks,
  `encode/1` and `decode/1`) drops in. This affects every SDK-mediated
  encode site uniformly:

    * `Restate.Context.set_state/3` value
    * `Restate.Context.get_state/2` decode
    * `Restate.Context.run/2,3` result
    * `Restate.Context.call/4,5` parameter + return
    * `Restate.Context.send/4,5` parameter
    * `Restate.Context.complete_awakeable/3` value
    * `Restate.Context.await_awakeable/2` result
    * Handler input + output

  The `/discover` manifest is **not** affected — the protocol pins it
  to JSON (`application/vnd.restate.endpointmanifest.v2+json`) and
  `Restate.Server.Manifest` always uses Jason directly.

  ## The `{:raw, bytes}` opt-out

  Independent of the configured serde, every encode site accepts a
  `{:raw, binary()}` tuple as a passthrough — the bytes go on the
  wire unmodified. Useful for the conformance Proxy test handler
  (forwards opaque pre-encoded payloads), for cross-serde
  compatibility shims, or for handlers that want to control the
  exact wire bytes for one specific call. The serde behaviour
  doesn't see `{:raw, ...}`; the wrappers in `Restate.Context`
  handle it.

  ## Writing a custom serde

      defmodule MyApp.Serde.Msgpack do
        @behaviour Restate.Serde

        @impl true
        def encode(term), do: Msgpax.pack!(term, iodata: false)

        @impl true
        def decode(""), do: nil
        def decode(bytes), do: Msgpax.unpack!(bytes)
      end

  Two requirements:

    1. `decode("")` must return `nil`. Restate sends an empty
       `Pb.Value{content: ""}` for "no value" — typically when
       reading state that has never been set, or when a handler
       returns `:ok`. Every impl must agree this maps to `nil` on
       the Elixir side.
    2. `encode/1` and `decode/1` should be a round-trip pair on the
       Elixir terms the user passes. Lossy encodes (e.g. dropping
       atoms) will surface as drift between writes and replays.
  """

  @doc """
  Encode an Elixir term to wire bytes.

  Implementations MUST be deterministic — the same term produces the
  same bytes. Required so `ctx.run` results journal the same value on
  the original execution and on every replay.
  """
  @callback encode(term()) :: binary()

  @doc """
  Decode wire bytes back to an Elixir term.

  `decode("")` MUST return `nil`. Restate uses the empty `Pb.Value`
  for "no value" / "absent state" semantics; every Restate SDK
  agrees on this convention.
  """
  @callback decode(binary()) :: term()

  @default_serde Restate.Serde.Json

  @doc """
  The currently-configured serde module.

  Reads `Application.get_env(:restate_server, :serde)`, defaults to
  `Restate.Serde.Json`. Resolved on every call so a runtime config
  swap (e.g. for tests) takes effect immediately — the cost is one
  ETS-backed app-env lookup per encode/decode, ~ns scale.
  """
  @spec impl() :: module()
  def impl, do: Application.get_env(:restate_server, :serde, @default_serde)

  @doc """
  Encode a term using the configured serde.

  Forwards to `impl().encode(term)`. The configured impl is read
  fresh on every call.
  """
  @spec encode(term()) :: binary()
  def encode(term), do: impl().encode(term)

  @doc """
  Decode wire bytes using the configured serde.

  Forwards to `impl().decode(bytes)`. The configured impl is read
  fresh on every call. `decode("")` returns `nil` regardless of
  impl (the behaviour requires it).
  """
  @spec decode(binary()) :: term()
  def decode(bytes) when is_binary(bytes), do: impl().decode(bytes)
end
