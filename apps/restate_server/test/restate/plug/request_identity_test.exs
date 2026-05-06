defmodule Restate.Plug.RequestIdentityTest do
  # async: false — touches `Application.put_env` and the
  # `:persistent_term` cache, both global.
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Restate.Plug.RequestIdentity, as: IdentityPlug
  alias Restate.RequestIdentity.Base58

  @opts IdentityPlug.init([])

  setup do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    key_string = "publickeyv1_" <> Base58.encode!(public)

    on_exit(fn ->
      Application.delete_env(:restate_server, :request_identity_keys)
      IdentityPlug.reset_cache()
    end)

    # Always start from a clean slate.
    Application.delete_env(:restate_server, :request_identity_keys)
    IdentityPlug.reset_cache()

    {:ok, public: public, private: private, key_string: key_string}
  end

  describe "no keys configured (dev mode)" do
    test "request passes through without verification" do
      conn =
        :post
        |> conn("/invoke/Foo/bar")
        |> IdentityPlug.call(@opts)

      refute conn.halted
      assert conn.status == nil
    end
  end

  describe "keys configured" do
    setup ctx do
      Application.put_env(:restate_server, :request_identity_keys, [ctx.key_string])
      IdentityPlug.reset_cache()
      :ok
    end

    test "valid signature passes through", ctx do
      jwt = build_jwt(ctx.private, %{"sub" => "test"})

      conn =
        :post
        |> conn("/invoke/Foo/bar")
        |> put_req_header("x-restate-signature-scheme", "v1")
        |> put_req_header("x-restate-jwt-v1", jwt)
        |> IdentityPlug.call(@opts)

      refute conn.halted
    end

    test "missing headers → 401" do
      conn =
        :post
        |> conn("/invoke/Foo/bar")
        |> IdentityPlug.call(@opts)

      assert conn.halted
      assert conn.status == 401
    end

    test "unsigned scheme → 401" do
      conn =
        :post
        |> conn("/invoke/Foo/bar")
        |> put_req_header("x-restate-signature-scheme", "unsigned")
        |> IdentityPlug.call(@opts)

      assert conn.halted
      assert conn.status == 401
    end

    test "wrong signing key → 401" do
      {_other_pub, other_priv} = :crypto.generate_key(:eddsa, :ed25519)
      jwt = build_jwt(other_priv, %{})

      conn =
        :post
        |> conn("/invoke/Foo/bar")
        |> put_req_header("x-restate-signature-scheme", "v1")
        |> put_req_header("x-restate-jwt-v1", jwt)
        |> IdentityPlug.call(@opts)

      assert conn.halted
      assert conn.status == 401
    end

    test "/discover is not verified", _ctx do
      conn =
        :get
        |> conn("/discover")
        |> IdentityPlug.call(@opts)

      refute conn.halted
    end

    test "custom :paths opt narrows the filter" do
      opts = IdentityPlug.init(paths: ["/invoke/Critical/"])

      # /invoke/Other/foo is outside the path filter — should pass without verification.
      conn =
        :post
        |> conn("/invoke/Other/foo")
        |> IdentityPlug.call(opts)

      refute conn.halted
    end
  end

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
    signature = :crypto.sign(:eddsa, :none, signing_input, [private_key, :ed25519])
    sig_b64 = Base.url_encode64(signature, padding: false)
    signing_input <> "." <> sig_b64
  end
end
