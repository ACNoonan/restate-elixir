defmodule Restate.Server.Endpoint do
  @moduledoc """
  Plug router serving the V5 service-protocol HTTP surface.

  Routes:

    * `GET /discover` — endpoint manifest as JSON. (Spec doc says
      `/discovery` but live restate-server hits `/discover` — verified
      against restate:latest in Apr 2026.)
    * `POST /invoke/:service/:handler` — runs the registered handler
      under a `Restate.Server.Invocation` process and returns the framed
      Command/Notification response stream.
  """

  use Plug.Router

  alias Dev.Restate.Service.Protocol, as: Pb
  alias Restate.Protocol.Framer
  alias Restate.Server.{Invocation, Manifest, Registry}

  @discovery_content_type "application/vnd.restate.endpointmanifest.v2+json"
  @invocation_content_type "application/vnd.restate.invocation.v5"
  @sdk_id "restate-sdk-elixir/0.1.0"

  plug Plug.Logger, log: :info
  plug :match
  plug :dispatch

  get "/discover" do
    body = Manifest.build() |> Jason.encode!()

    conn
    |> put_resp_header("content-type", @discovery_content_type)
    |> put_resp_header("x-restate-server", @sdk_id)
    |> send_resp(200, body)
  end

  post "/invoke/:service/:handler" do
    cond do
      Restate.Server.DrainCoordinator.draining?() ->
        # Demo 3: graceful drain. Endpoint is rejecting new work so the
        # in-flight invocations can finish. Restate's ingress will retry
        # the call against another instance. 503 is the agreed wire
        # signal for "service temporarily unavailable, retry elsewhere."
        conn
        |> put_resp_header("retry-after", "1")
        |> send_resp(503, "draining")

      true ->
        dispatch_invocation(conn, service, handler)
    end
  end

  defp dispatch_invocation(conn, service, handler) do
    case Registry.lookup_handler(service, handler) do
      :not_found ->
        send_resp(conn, 404, "")

      %{mfa: mfa} ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_048_576)

        with {:ok, frames, _leftover} <- Framer.decode_all(body),
             {:ok, start_msg, input, replay_journal} <- extract_invocation(frames) do
          {:ok, pid} = Invocation.start_link({start_msg, input, replay_journal, mfa})
          response_body = Invocation.await_response(pid)

          conn
          |> put_resp_header("content-type", @invocation_content_type)
          |> put_resp_header("x-restate-server", @sdk_id)
          |> send_resp(200, response_body)
        else
          {:error, reason} -> send_resp(conn, 400, "decode error: #{inspect(reason)}")
        end
    end
  end

  match _ do
    send_resp(conn, 404, "")
  end

  # The runtime always sends StartMessage first and InputCommandMessage
  # second. Everything after Input is the recorded journal the runtime is
  # replaying — recorded *CommandMessages and any *CompletionNotifications
  # that have already arrived for previously-emitted completable commands.
  defp extract_invocation([
         %Restate.Protocol.Frame{message: %Pb.StartMessage{} = start},
         %Restate.Protocol.Frame{message: %Pb.InputCommandMessage{value: value}}
         | rest
       ]) do
    {:ok, start, decode_input(value), rest}
  end

  defp extract_invocation(_), do: {:error, :missing_start_or_input}

  defp decode_input(nil), do: nil
  defp decode_input(%Pb.Value{content: ""}), do: nil
  defp decode_input(%Pb.Value{content: bytes}), do: Jason.decode!(bytes)
end
