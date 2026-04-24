defmodule Restate.Server.Manifest do
  @moduledoc """
  Builds the discovery manifest returned at `GET /discovery`.

  Schema is defined in
  `apps/restate_protocol/proto/endpoint_manifest_schema.json`. We advertise
  REQUEST_RESPONSE protocol mode (see PLAN.md — Bandit HTTP/2 full-duplex
  is deferred past Week 1) and pin both min and max protocol versions to 5.
  """

  @doc """
  Build the manifest map for the given service definitions.

  `services` is a list of `%{name: binary, ty: \"SERVICE\" | \"VIRTUAL_OBJECT\" | \"WORKFLOW\", handlers: [%{name: binary}]}`.
  """
  @spec build([map()]) :: map()
  def build(services) do
    %{
      protocolMode: "REQUEST_RESPONSE",
      minProtocolVersion: 5,
      maxProtocolVersion: 5,
      services: services
    }
  end
end
