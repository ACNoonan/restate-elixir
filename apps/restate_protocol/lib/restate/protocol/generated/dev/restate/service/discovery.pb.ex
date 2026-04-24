defmodule Dev.Restate.Service.Discovery.ServiceDiscoveryProtocolVersion do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "dev.restate.service.discovery.ServiceDiscoveryProtocolVersion",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :SERVICE_DISCOVERY_PROTOCOL_VERSION_UNSPECIFIED, 0
  field :V1, 1
  field :V2, 2
end
