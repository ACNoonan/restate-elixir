defmodule Restate.Server.Manifest do
  @moduledoc """
  Builds the discovery manifest returned at `GET /discover`.

  Schema is defined in
  `apps/restate_protocol/proto/endpoint_manifest_schema.json`. We advertise
  REQUEST_RESPONSE protocol mode (Bandit HTTP/2 same-stream full-duplex
  streaming is the v0.3 carryover; see `docs/known-risks.md`) and the
  protocol-version range we accept on `/invoke`.

  V5 is the original V5 command/notification split (immutable journal,
  separate completions). V6 adds two things: `StartMessage.random_seed`
  for deterministic per-invocation RNG (`Restate.Context.random_*`) and
  a typed `Failure.metadata` field. We already implemented metadata on
  V5 (the runtime is permissive); V6 makes it official and also lights
  up the random-seed API. V7 changes suspension semantics — Future-based
  `awaiting_on` — and is the next bump (carried to a future release).
  """

  alias Restate.Server.Registry

  @min_protocol_version 5
  @max_protocol_version 6

  @doc "Lowest service-protocol version this SDK will accept."
  @spec min_protocol_version() :: pos_integer()
  def min_protocol_version, do: @min_protocol_version

  @doc "Highest service-protocol version this SDK will accept."
  @spec max_protocol_version() :: pos_integer()
  def max_protocol_version, do: @max_protocol_version

  @doc "Build the manifest map from the live service registry."
  @spec build() :: map()
  def build do
    %{
      protocolMode: "REQUEST_RESPONSE",
      minProtocolVersion: @min_protocol_version,
      maxProtocolVersion: @max_protocol_version,
      services: Enum.map(Registry.list_services(), &service_to_manifest/1)
    }
  end

  defp service_to_manifest(%{name: name, type: type, handlers: handlers}) do
    %{
      name: name,
      ty: encode_service_type(type),
      handlers: Enum.map(handlers, &handler_to_manifest/1)
    }
  end

  defp handler_to_manifest(%{name: name, type: type}) do
    base = %{name: name}

    case encode_handler_type(type) do
      nil -> base
      ty -> Map.put(base, :ty, ty)
    end
  end

  defp encode_service_type(:service), do: "SERVICE"
  defp encode_service_type(:virtual_object), do: "VIRTUAL_OBJECT"
  defp encode_service_type(:workflow), do: "WORKFLOW"

  defp encode_handler_type(nil), do: nil
  defp encode_handler_type(:exclusive), do: "EXCLUSIVE"
  defp encode_handler_type(:shared), do: "SHARED"
  defp encode_handler_type(:workflow), do: "WORKFLOW"
end
