defmodule Restate.Serde.Json do
  @moduledoc """
  Default `Restate.Serde` impl: JSON via [`Jason`](https://hex.pm/packages/jason).

  Matches the wire format every official Restate SDK speaks, so a
  polyglot deployment (TS / Java / Python / Go + Elixir) interoperates
  out of the box without any per-service serde negotiation. This impl
  is what the SDK uses unless `config :restate_server, :serde, ...`
  overrides it.

  ## Encoding

  Whatever `Jason.encode!/1` accepts: maps with binary or atom keys,
  lists, binaries, integers, floats, booleans, `nil`. Atoms encode as
  strings; tuples are not supported — wrap them in lists or maps if
  you need to carry tuple-shaped data through the journal.

  ## Decoding

  `decode("")` returns `nil` (the Restate convention for "no value" /
  "absent state"). Any other input goes through `Jason.decode!/1`.
  Decoded objects come back with binary keys (`%{"counter" => 1}`,
  not `%{counter: 1}`); use `Map.get/3` with binary keys in handlers
  or convert with a known key set.
  """

  @behaviour Restate.Serde

  @impl true
  def encode(term), do: Jason.encode!(term)

  @impl true
  def decode(""), do: nil
  def decode(bytes) when is_binary(bytes), do: Jason.decode!(bytes)
end
