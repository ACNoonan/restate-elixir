defmodule Restate.Server.Manifest do
  @moduledoc """
  Builds the discovery manifest returned at `GET /discover`.

  Schema is defined in
  `apps/restate_protocol/proto/endpoint_manifest_schema.json`. We advertise
  REQUEST_RESPONSE protocol mode (see PLAN.md — Bandit HTTP/2 full-duplex
  is deferred past Week 1) and pin both min and max protocol versions to 5.
  """

  alias Restate.Server.Registry

  @doc "Build the manifest map from the live service registry."
  @spec build() :: map()
  def build do
    %{
      protocolMode: "REQUEST_RESPONSE",
      minProtocolVersion: 5,
      maxProtocolVersion: 5,
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
