defmodule Restate.RequestIdentityTest do
  use ExUnit.Case, async: true

  alias Restate.RequestIdentity
  alias Restate.RequestIdentity.Base58

  setup do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    key_string = "publickeyv1_" <> Base58.encode!(public)
    {:ok, public: public, private: private, key_string: key_string}
  end

  describe "from_keys/1" do
    test "rejects empty list" do
      assert_raise ArgumentError, ~r/at least one key/, fn ->
        RequestIdentity.from_keys([])
      end
    end

    test "rejects bad prefix" do
      assert_raise ArgumentError, ~r/keys must start with/, fn ->
        RequestIdentity.from_keys(["not_the_right_prefix_AAAA"])
      end
    end

    test "rejects wrong decoded length" do
      # 16 random bytes is short; valid base58 but not 32 bytes after decode.
      short = "publickeyv1_" <> Base58.encode!(:crypto.strong_rand_bytes(16))

      assert_raise ArgumentError, ~r/expected 32-byte/, fn ->
        RequestIdentity.from_keys([short])
      end
    end

    test "accepts a valid key", %{key_string: key_string} do
      verifier = RequestIdentity.from_keys([key_string])
      assert %RequestIdentity{keys: [key]} = verifier
      assert byte_size(key) == 32
    end
  end

  describe "verify_request/2 — happy path" do
    test "valid JWT signed by configured key", ctx do
      verifier = RequestIdentity.from_key(ctx.key_string)
      jwt = build_jwt(ctx.private, %{"sub" => "test"})

      headers = %{
        "x-restate-signature-scheme" => "v1",
        "x-restate-jwt-v1" => jwt
      }

      assert :ok = RequestIdentity.verify_request(verifier, headers)
    end

    test "header lookup is case-insensitive", ctx do
      verifier = RequestIdentity.from_key(ctx.key_string)
      jwt = build_jwt(ctx.private, %{})

      headers = %{
        "X-Restate-Signature-Scheme" => "v1",
        "X-Restate-JWT-V1" => jwt
      }

      assert :ok = RequestIdentity.verify_request(verifier, headers)
    end

    test "list-of-tuples header shape (matches Plug.Conn.req_headers)", ctx do
      verifier = RequestIdentity.from_key(ctx.key_string)
      jwt = build_jwt(ctx.private, %{})

      headers = [
        {"x-restate-signature-scheme", "v1"},
        {"x-restate-jwt-v1", jwt}
      ]

      assert :ok = RequestIdentity.verify_request(verifier, headers)
    end

    test "multi-key rotation: accepts JWT signed by any configured key", ctx do
      {old_pub, _old_priv} = :crypto.generate_key(:eddsa, :ed25519)
      old_key_string = "publickeyv1_" <> Base58.encode!(old_pub)

      verifier = RequestIdentity.from_keys([old_key_string, ctx.key_string])
      jwt = build_jwt(ctx.private, %{})

      headers = %{
        "x-restate-signature-scheme" => "v1",
        "x-restate-jwt-v1" => jwt
      }

      assert :ok = RequestIdentity.verify_request(verifier, headers)
    end
  end

  describe "verify_request/2 — failures" do
    setup ctx do
      {:ok, verifier: RequestIdentity.from_key(ctx.key_string)}
    end

    test "missing scheme header", %{verifier: verifier} do
      assert {:error, {:missing_header, "x-restate-signature-scheme"}} =
               RequestIdentity.verify_request(verifier, %{})
    end

    test "missing JWT header when scheme is v1", %{verifier: verifier} do
      assert {:error, {:missing_header, "x-restate-jwt-v1"}} =
               RequestIdentity.verify_request(verifier, %{
                 "x-restate-signature-scheme" => "v1"
               })
    end

    test "unsigned scheme is rejected", %{verifier: verifier} do
      assert {:error, :unsigned_request} =
               RequestIdentity.verify_request(verifier, %{
                 "x-restate-signature-scheme" => "unsigned"
               })
    end

    test "unknown scheme is rejected", %{verifier: verifier} do
      assert {:error, {:unknown_signature_scheme, "v999"}} =
               RequestIdentity.verify_request(verifier, %{
                 "x-restate-signature-scheme" => "v999"
               })
    end

    test "JWT with two segments is malformed", %{verifier: verifier} do
      assert {:error, :malformed_jwt} =
               RequestIdentity.verify_request(verifier, %{
                 "x-restate-signature-scheme" => "v1",
                 "x-restate-jwt-v1" => "header.payload"
               })
    end

    test "JWT with non-base64url signature segment is malformed", %{verifier: verifier} do
      assert {:error, :malformed_signature} =
               RequestIdentity.verify_request(verifier, %{
                 "x-restate-signature-scheme" => "v1",
                 "x-restate-jwt-v1" => "h.p.!!!!!!"
               })
    end

    test "valid JWT but signed by a different key", %{verifier: verifier} do
      {_other_pub, other_priv} = :crypto.generate_key(:eddsa, :ed25519)
      jwt = build_jwt(other_priv, %{})

      assert {:error, :invalid_signature} =
               RequestIdentity.verify_request(verifier, %{
                 "x-restate-signature-scheme" => "v1",
                 "x-restate-jwt-v1" => jwt
               })
    end
  end

  # --- helpers ---

  defp build_jwt(private_key, claims) do
    header_b64 =
      %{"alg" => "EdDSA", "typ" => "JWT"}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    payload_b64 =
      claims
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    signing_input = header_b64 <> "." <> payload_b64

    signature =
      :crypto.sign(:eddsa, :none, signing_input, [private_key, :ed25519])

    sig_b64 = Base.url_encode64(signature, padding: false)

    signing_input <> "." <> sig_b64
  end
end
