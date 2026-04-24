defmodule Restate.Server.Endpoint do
  @moduledoc """
  Plug router serving the V3 service-protocol HTTP surface.

  Two routes for Week 1:

    * `GET /discover` — returns the endpoint manifest as JSON. (Spec doc
      says `/discovery` but live restate-server hits `/discover` — verified
      against restate:latest in Apr 2026.)
    * `POST /invoke/:service/:handler` — non-durable echo. Reads the framed
      request body and replies with `OutputEntryMessage("hello")` +
      `EndMessage`. No journal logic yet — that arrives in Week 2.
  """

  use Plug.Router

  alias Dev.Restate.Service.Protocol, as: Pb
  alias Restate.Protocol.Framer
  alias Restate.Server.Manifest

  @discovery_content_type "application/vnd.restate.endpointmanifest.v2+json"
  @invocation_content_type "application/vnd.restate.invocation.v3"
  @sdk_id "restate-sdk-elixir/0.1.0"

  # Hardcoded for the Week 1 echo. A real registry comes in Week 2.
  @services [
    %{name: "Greeter", ty: "SERVICE", handlers: [%{name: "greet"}]}
  ]

  plug Plug.Logger, log: :info
  plug :match
  plug :dispatch

  get "/discover" do
    body = @services |> Manifest.build() |> Jason.encode!()

    conn
    |> put_resp_header("content-type", @discovery_content_type)
    |> put_resp_header("x-restate-server", @sdk_id)
    |> send_resp(200, body)
  end

  post "/invoke/:service/:handler" do
    case lookup_handler(service, handler) do
      :not_found ->
        send_resp(conn, 404, "")

      :ok ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_048_576)

        case Framer.decode_all(body) do
          {:ok, _frames, _leftover} ->
            response =
              Framer.encode(%Pb.OutputEntryMessage{result: {:value, Jason.encode!("hello")}}) <>
                Framer.encode(%Pb.EndMessage{})

            conn
            |> put_resp_header("content-type", @invocation_content_type)
            |> put_resp_header("x-restate-server", @sdk_id)
            |> send_resp(200, response)

          {:error, reason} ->
            send_resp(conn, 400, "decode error: #{inspect(reason)}")
        end
    end
  end

  match _ do
    send_resp(conn, 404, "")
  end

  defp lookup_handler(service, handler) do
    Enum.find_value(@services, :not_found, fn svc ->
      if svc.name == service and Enum.any?(svc.handlers, &(&1.name == handler)) do
        :ok
      end
    end)
  end
end
