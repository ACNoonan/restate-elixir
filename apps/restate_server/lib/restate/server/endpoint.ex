defmodule Restate.Server.Endpoint do
  @moduledoc """
  Plug router serving the V5/V6 service-protocol HTTP surface.

  The protocol version is negotiated per request via the `content-type`
  header: the runtime picks a version inside the min..max range
  advertised by `/discover`, sends `application/vnd.restate.invocation.vN`,
  and the response mirrors that version. See `Restate.Server.Manifest`
  for the advertised range and `negotiate_protocol_version/1` below for
  the validation path (415 on out-of-range / missing / malformed).

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
  @invocation_content_type_prefix "application/vnd.restate.invocation."
  @sdk_id "restate-sdk-elixir/0.1.0"

  plug Plug.Logger, log: :info
  # Enforces `Restate.RequestIdentity` on `/invoke/*` when the
  # `:request_identity_keys` app env is configured. No-op otherwise
  # so dev / docker-compose loops without signing keep working.
  # `/discover` is intentionally excluded — Restate's discovery
  # request isn't signed.
  plug Restate.Plug.RequestIdentity
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
        case negotiate_protocol_version(conn) do
          {:ok, version} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_048_576)

            with {:ok, frames, _leftover} <- Framer.decode_all(body),
                 {:ok, start_msg, input, replay_journal} <- extract_invocation(frames) do
              run_invocation(
                conn,
                service,
                handler,
                mfa,
                start_msg,
                input,
                replay_journal,
                version
              )
            else
              {:error, reason} -> send_resp(conn, 400, "decode error: #{inspect(reason)}")
            end

          {:error, status, message} ->
            send_resp(conn, status, message)
        end
    end
  end

  # Restate negotiates the service-protocol version per-invocation via
  # the request `content-type`: it picks a version in the
  # min..max range advertised by `/discover`. We mirror it back on the
  # response. Validating here means a runtime that drifts ahead of our
  # range gets a clean 415 instead of a confusing decode error
  # downstream.
  defp negotiate_protocol_version(conn) do
    case Plug.Conn.get_req_header(conn, "content-type") do
      [content_type | _] ->
        with {:ok, version} <- parse_protocol_version(content_type),
             true <-
               version >= Manifest.min_protocol_version() and
                 version <= Manifest.max_protocol_version() do
          {:ok, version}
        else
          :error ->
            {:error, 415, "expected #{@invocation_content_type_prefix}vN content-type"}

          false ->
            {:error, 415,
             "unsupported service-protocol version; advertised range is " <>
               "v#{Manifest.min_protocol_version()}..v#{Manifest.max_protocol_version()}"}
        end

      [] ->
        {:error, 415, "missing content-type"}
    end
  end

  defp parse_protocol_version(content_type) do
    with @invocation_content_type_prefix <> rest <- content_type,
         "v" <> version_str <- rest,
         {version, ""} <- Integer.parse(version_str) do
      {:ok, version}
    else
      _ -> :error
    end
  end

  # Wrap the Invocation's lifecycle in `:telemetry.span` so attached
  # handlers see correlated `[:restate, :invocation, :start | :stop |
  # :exception]` events with measurements (`system_time`,
  # `monotonic_time`, `duration`) and metadata (`service`, `handler`,
  # `outcome`, `response_bytes`). See `Restate.Telemetry` for the
  # full event surface.
  defp run_invocation(conn, service, handler, mfa, start_msg, input, replay_journal, version) do
    dispatch_meta = %{service: service, handler: handler, protocol_version: version}

    response_body =
      :telemetry.span([:restate, :invocation], dispatch_meta, fn ->
        {:ok, pid} =
          Invocation.start_link(
            {start_msg, input, replay_journal, mfa, dispatch_meta}
          )

        {outcome, body} = Invocation.await_response(pid)

        # `:telemetry.span` does NOT carry `start_metadata` over to
        # the `:stop` event — only what the function returns becomes
        # stop metadata. Merge `dispatch_meta` in explicitly so
        # `service` / `handler` are present on both ends of the span.
        stop_meta =
          Map.merge(dispatch_meta, %{
            outcome: outcome,
            response_bytes: byte_size(body)
          })

        {body, stop_meta}
      end)

    conn
    |> put_resp_header("content-type", @invocation_content_type_prefix <> "v#{version}")
    |> put_resp_header("x-restate-server", @sdk_id)
    |> send_resp(200, response_body)
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
