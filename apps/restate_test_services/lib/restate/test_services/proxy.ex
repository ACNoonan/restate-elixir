defmodule Restate.TestServices.Proxy do
  @moduledoc """
  Mirror of `dev.restate.sdktesting.contracts.Proxy`. Used by the
  conformance harness to validate `ctx.call` and `ctx.send` across
  service boundaries.

  ## Input shape

      %{
        "serviceName" => "Counter",
        "virtualObjectKey" => "k1",  # null/missing for plain Service
        "handlerName" => "add",
        "message" => [50, 51],       # bytes-as-array-of-numbers (kotlinx.serialization shape)
        "delayMillis" => 100,        # optional; only used by oneWayCall
        "idempotencyKey" => "..."    # optional
      }

  ## Wire-bytes round-trip

  Java's `kotlinx.serialization` encodes a `ByteArray` as a JSON array of
  numbers (each byte 0–255). Our handler decodes that list to a binary
  via `:binary.list_to_bin/1`, passes the binary as `parameter` to
  `Restate.Context.call/5` (which recognizes raw binaries and forwards
  them as-is), and on return wraps the result bytes back into a list
  for the JSON encoder.
  """

  alias Restate.Context

  @doc """
  Synchronous proxy: calls the target handler and returns its raw
  response bytes (as an array of byte-integers).
  """
  def call(%Context{} = ctx, %{"serviceName" => service, "handlerName" => handler} = req) do
    bytes = result_to_binary(Context.call(ctx, service, handler, {:raw, message_to_binary(req)}, opts(req)))
    :binary.bin_to_list(bytes)
  end

  @doc """
  Fire-and-forget proxy: returns the spawned invocation id.
  """
  def one_way_call(
        %Context{} = ctx,
        %{"serviceName" => service, "handlerName" => handler} = req
      ) do
    Context.send(ctx, service, handler, {:raw, message_to_binary(req)}, opts(req))
  end

  @doc """
  Fan out multiple calls (sequentially in v0.1 — combinator semantics
  arrive when we add awaitable composition in v0.2). Each request is
  either a regular call or a one-way send.

  `awaitAtTheEnd` is honoured trivially since we don't have parallel
  awaitables yet — every call is awaited at its own callsite.
  """
  def many_calls(%Context{} = ctx, requests) when is_list(requests) do
    Enum.each(requests, fn %{"proxyRequest" => req, "oneWayCall" => one_way?} ->
      if one_way? do
        one_way_call(ctx, req)
      else
        call(ctx, req)
      end
    end)

    nil
  end

  defp message_to_binary(%{"message" => list}) when is_list(list), do: :binary.list_to_bin(list)
  defp message_to_binary(_), do: <<>>

  # `Restate.Context.call/5` Jason-decodes the response, so by the time we
  # see it the wire bytes are gone. Re-encode the term so the test client
  # gets back the original JSON shape (e.g. a string is `"PING"` with
  # surrounding quotes, not bare `PING`). Don't short-circuit on binaries:
  # an Elixir string is also a binary, and the test expects it to come
  # back as a JSON string literal.
  defp result_to_binary(term), do: Jason.encode!(term)

  defp opts(%{"virtualObjectKey" => key} = req) when is_binary(key) do
    [key: key, idempotency_key: Map.get(req, "idempotencyKey")]
  end

  defp opts(req) do
    [idempotency_key: Map.get(req, "idempotencyKey")]
  end
end
