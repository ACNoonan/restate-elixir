defmodule Restate.Server.EndpointTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias Dev.Restate.Service.Protocol, as: Pb
  alias Restate.Protocol.{Frame, Framer}
  alias Restate.Server.Endpoint

  @opts Endpoint.init([])

  describe "GET /discover" do
    test "returns the manifest with content-type vnd.restate.endpointmanifest.v2+json" do
      conn = :get |> conn("/discover") |> Endpoint.call(@opts)

      assert conn.status == 200

      assert get_resp_header(conn, "content-type") == [
               "application/vnd.restate.endpointmanifest.v2+json"
             ]

      manifest = Jason.decode!(conn.resp_body)
      assert manifest["protocolMode"] == "REQUEST_RESPONSE"
      assert manifest["minProtocolVersion"] == 3
      assert manifest["maxProtocolVersion"] == 3

      assert [%{"name" => "Greeter", "ty" => "SERVICE", "handlers" => [%{"name" => "greet"}]}] =
               manifest["services"]
    end

    test "advertises the SDK via x-restate-server" do
      conn = :get |> conn("/discover") |> Endpoint.call(@opts)
      assert ["restate-sdk-elixir/0.1.0"] = get_resp_header(conn, "x-restate-server")
    end
  end

  describe "POST /invoke/:service/:handler" do
    test "echoes Output(\"hello\") + End for the registered handler" do
      body = invocation_body(name: "world")

      conn =
        :post
        |> conn("/invoke/Greeter/greet", body)
        |> put_req_header("content-type", "application/vnd.restate.invocation.v3")
        |> Endpoint.call(@opts)

      assert conn.status == 200

      assert get_resp_header(conn, "content-type") == [
               "application/vnd.restate.invocation.v3"
             ]

      assert {:ok, frames, ""} = Framer.decode_all(conn.resp_body)

      assert [
               %Frame{message: %Pb.OutputEntryMessage{result: {:value, value_bytes}}},
               %Frame{message: %Pb.EndMessage{}}
             ] = frames

      assert Jason.decode!(value_bytes) == "hello"
    end

    test "404 when the service is not registered" do
      conn =
        :post
        |> conn("/invoke/Unknown/greet", invocation_body(name: "x"))
        |> Endpoint.call(@opts)

      assert conn.status == 404
    end

    test "404 when the handler is not registered" do
      conn =
        :post
        |> conn("/invoke/Greeter/wave", invocation_body(name: "x"))
        |> Endpoint.call(@opts)

      assert conn.status == 404
    end

    test "404 for arbitrary paths" do
      conn = :get |> conn("/nope") |> Endpoint.call(@opts)
      assert conn.status == 404
    end
  end

  defp invocation_body(opts) do
    name = Keyword.fetch!(opts, :name)

    start = %Pb.StartMessage{id: <<0, 1, 2, 3>>, debug_id: "test", known_entries: 1}
    input = %Pb.InputEntryMessage{value: Jason.encode!(name)}

    Framer.encode(start) <> Framer.encode(input)
  end
end
