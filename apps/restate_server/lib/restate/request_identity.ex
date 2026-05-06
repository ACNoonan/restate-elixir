defmodule Restate.RequestIdentity do
  @moduledoc """
  Verifies signed requests from `restate-server`.

  Compatible with the Java SDK's `sdk-request-identity`: the runtime
  sends two headers when signing is enabled —

    * `x-restate-signature-scheme: v1` (or `unsigned`)
    * `x-restate-jwt-v1: <compact-JWT>`

  — and the JWT is signed with **Ed25519** (raw EdDSA over Curve25519).
  Public keys are distributed as `publickeyv1_<base58>` strings; the
  base58-decoded payload is exactly 32 bytes (the Ed25519 public key).
  This module verifies the JWT signature against any of the configured
  public keys. Claim payload validation is intentionally not performed
  — that matches the Java SDK and Restate's threat model (the runtime
  rotates keys, the SDK trusts the signature).

  ## Pure verifier API

      verifier = Restate.RequestIdentity.from_key("publickeyv1_...")

      case Restate.RequestIdentity.verify_request(verifier, conn.req_headers) do
        :ok ->
          # signed by one of the configured keys; let it through
        {:error, reason} ->
          # reject; reason is one of the values in the @verify_error type
      end

  Most users won't call this directly — wire `Restate.Plug.RequestIdentity`
  into the request pipeline instead, which handles 401-on-failure and
  is auto-installed in `Restate.Server.Endpoint`.

  ## Configuration

  Set `:request_identity_keys` in the `:restate_server` app env to a
  list of `publickeyv1_*` strings. Without this config the Plug is a
  no-op — useful in dev / docker-compose loops where signing is off.

      # config/runtime.exs
      if keys = System.get_env("RESTATE_REQUEST_IDENTITY_KEYS") do
        config :restate_server,
          request_identity_keys: String.split(keys, ",", trim: true)
      end

  Multiple keys are supported for rolling rotation: a request is
  accepted if its JWT signature matches *any* configured key.
  """

  alias Restate.RequestIdentity.Base58

  @signature_scheme_header "x-restate-signature-scheme"
  @jwt_header "x-restate-jwt-v1"
  @scheme_v1 "v1"
  @scheme_unsigned "unsigned"
  @key_prefix "publickeyv1_"

  defstruct keys: []

  @type t :: %__MODULE__{keys: [binary()]}

  @type verify_error ::
          :unsigned_request
          | :invalid_signature
          | :malformed_jwt
          | :malformed_signature
          | {:missing_header, String.t()}
          | {:unknown_signature_scheme, String.t()}

  @doc """
  Build a verifier from a list of `publickeyv1_*` key strings.

  Raises `ArgumentError` on bad prefix, malformed base58, or wrong
  decoded length. Validation runs once at construction so per-request
  verification is just a signature check.
  """
  @spec from_keys([binary(), ...]) :: t()
  def from_keys(keys) when is_list(keys) and keys != [] do
    %__MODULE__{keys: Enum.map(keys, &parse_key!/1)}
  end

  def from_keys([]) do
    raise ArgumentError, "Restate.RequestIdentity.from_keys/1 requires at least one key"
  end

  @doc """
  Convenience for the common single-key case.
  """
  @spec from_key(binary()) :: t()
  def from_key(key) when is_binary(key), do: from_keys([key])

  @doc """
  Verify a request's signature headers.

  `headers` is anything enumerable as `{name, value}` tuples — a
  `Plug.Conn.t/0`'s `req_headers` (list of two-tuples) or a
  test-convenience map. Header names are matched case-insensitively
  per HTTP convention.
  """
  @spec verify_request(t(), Enumerable.t()) :: :ok | {:error, verify_error()}
  def verify_request(%__MODULE__{} = verifier, headers) do
    case fetch_header(headers, @signature_scheme_header) do
      {:ok, @scheme_v1} ->
        with {:ok, jwt} <- fetch_header_or_error(headers, @jwt_header) do
          verify_jwt(verifier, jwt)
        end

      {:ok, @scheme_unsigned} ->
        {:error, :unsigned_request}

      {:ok, scheme} ->
        {:error, {:unknown_signature_scheme, scheme}}

      :error ->
        {:error, {:missing_header, @signature_scheme_header}}
    end
  end

  # --- internals ---

  defp parse_key!(@key_prefix <> b58) do
    case Base58.decode!(b58) do
      <<bytes::binary-size(32)>> ->
        bytes

      bytes ->
        raise ArgumentError,
              "Restate.RequestIdentity: expected 32-byte Ed25519 public key, " <>
                "got #{byte_size(bytes)} bytes after base58 decode"
    end
  end

  defp parse_key!(other) when is_binary(other) do
    raise ArgumentError,
          "Restate.RequestIdentity: keys must start with #{inspect(@key_prefix)}, " <>
            "got #{inspect(other)}"
  end

  defp verify_jwt(%__MODULE__{keys: keys}, jwt) when is_binary(jwt) do
    case String.split(jwt, ".") do
      [header_b64, payload_b64, sig_b64] ->
        signed_input = header_b64 <> "." <> payload_b64

        case Base.url_decode64(sig_b64, padding: false) do
          {:ok, signature} ->
            if Enum.any?(keys, &valid_ed25519?(&1, signed_input, signature)) do
              :ok
            else
              {:error, :invalid_signature}
            end

          :error ->
            {:error, :malformed_signature}
        end

      _ ->
        {:error, :malformed_jwt}
    end
  end

  defp valid_ed25519?(public_key, message, signature) do
    :crypto.verify(:eddsa, :none, message, signature, [public_key, :ed25519])
  rescue
    # Defensive: malformed signature lengths can raise from :crypto.
    # Treat any raised exception as a verification failure.
    _ -> false
  end

  defp fetch_header_or_error(headers, name) do
    case fetch_header(headers, name) do
      {:ok, _} = ok -> ok
      :error -> {:error, {:missing_header, name}}
    end
  end

  # Header names are case-insensitive (RFC 7230 §3.2). Plug normalises
  # to lowercase but we don't assume that here so the verifier works
  # against any source of headers.
  defp fetch_header(headers, name) do
    target = String.downcase(name)

    Enum.find_value(headers, :error, fn {k, v} ->
      if String.downcase(to_string(k)) == target do
        {:ok, to_string(v)}
      else
        nil
      end
    end)
  end
end
