defmodule Restate.Server.EndpointTest do
  # async: false because the registry uses :persistent_term (global state).
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Dev.Restate.Service.Protocol, as: Pb
  alias Restate.Protocol.{Frame, Framer}
  alias Restate.Server.{Endpoint, Registry}

  defmodule TestHandler do
    @moduledoc false
    alias Restate.Context

    def count(ctx, _input) do
      n = (Context.get_state(ctx, "counter") || 0) + 1
      Context.set_state(ctx, "counter", n)
      "hello #{n}"
    end
  end

  @opts Endpoint.init([])

  setup do
    Registry.reset()

    Registry.register_service(%{
      name: "Greeter",
      type: :virtual_object,
      handlers: [%{name: "count", type: :exclusive, mfa: {TestHandler, :count, 2}}]
    })

    :ok
  end

  describe "GET /discover" do
    test "manifest reflects the registered services" do
      conn = :get |> conn("/discover") |> Endpoint.call(@opts)

      assert conn.status == 200

      assert get_resp_header(conn, "content-type") == [
               "application/vnd.restate.endpointmanifest.v2+json"
             ]

      manifest = Jason.decode!(conn.resp_body)
      assert manifest["protocolMode"] == "REQUEST_RESPONSE"
      assert manifest["minProtocolVersion"] == 5
      assert manifest["maxProtocolVersion"] == 5

      assert [
               %{
                 "name" => "Greeter",
                 "ty" => "VIRTUAL_OBJECT",
                 "handlers" => [%{"name" => "count", "ty" => "EXCLUSIVE"}]
               }
             ] = manifest["services"]
    end

    test "advertises the SDK via x-restate-server" do
      conn = :get |> conn("/discover") |> Endpoint.call(@opts)
      assert ["restate-sdk-elixir/0.1.0"] = get_resp_header(conn, "x-restate-server")
    end
  end

  describe "POST /invoke/:service/:handler" do
    test "first invocation: counter starts at 1; emits SetState + Output + End" do
      conn =
        :post
        |> conn("/invoke/Greeter/count", invocation_body())
        |> put_req_header("content-type", "application/vnd.restate.invocation.v5")
        |> Endpoint.call(@opts)

      assert conn.status == 200

      assert get_resp_header(conn, "content-type") == [
               "application/vnd.restate.invocation.v5"
             ]

      assert {:ok, frames, ""} = Framer.decode_all(conn.resp_body)

      assert [
               %Frame{
                 message: %Pb.SetStateCommandMessage{
                   key: "counter",
                   value: %Pb.Value{content: "1"}
                 }
               },
               %Frame{
                 message: %Pb.OutputCommandMessage{
                   result: {:value, %Pb.Value{content: out}}
                 }
               },
               %Frame{message: %Pb.EndMessage{}}
             ] = frames

      assert Jason.decode!(out) == "hello 1"
    end

    test "second invocation: state_map seeds counter; output reads from it" do
      body = invocation_body(state: %{"counter" => "1"})

      conn =
        :post
        |> conn("/invoke/Greeter/count", body)
        |> put_req_header("content-type", "application/vnd.restate.invocation.v5")
        |> Endpoint.call(@opts)

      assert {:ok, frames, ""} = Framer.decode_all(conn.resp_body)

      [_set, output, _end_] = frames
      %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}} = output.message
      assert Jason.decode!(out) == "hello 2"
    end

    test "404 when the service is not registered" do
      conn =
        :post
        |> conn("/invoke/Unknown/count", invocation_body())
        |> Endpoint.call(@opts)

      assert conn.status == 404
    end

    test "404 when the handler is not registered" do
      conn =
        :post
        |> conn("/invoke/Greeter/wave", invocation_body())
        |> Endpoint.call(@opts)

      assert conn.status == 404
    end

    test "404 for arbitrary paths" do
      conn = :get |> conn("/nope") |> Endpoint.call(@opts)
      assert conn.status == 404
    end
  end

  defp invocation_body(opts \\ []) do
    state_entries =
      opts
      |> Keyword.get(:state, %{})
      |> Enum.map(fn {k, v} -> %Pb.StartMessage.StateEntry{key: k, value: v} end)

    start = %Pb.StartMessage{
      id: <<0, 1, 2, 3>>,
      debug_id: "test",
      known_entries: 1,
      state_map: state_entries,
      key: "world"
    }

    input = %Pb.InputCommandMessage{value: %Pb.Value{content: Jason.encode!(nil)}}

    Framer.encode(start) <> Framer.encode(input)
  end
end
