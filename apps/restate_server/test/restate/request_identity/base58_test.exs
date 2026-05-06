defmodule Restate.RequestIdentity.Base58Test do
  use ExUnit.Case, async: true

  alias Restate.RequestIdentity.Base58

  describe "decode!/1" do
    test "empty input → empty output" do
      assert Base58.decode!("") == <<>>
    end

    test "single '1' → single zero byte" do
      assert Base58.decode!("1") == <<0>>
    end

    test "all '1's → equal-length zero bytes" do
      assert Base58.decode!("111") == <<0, 0, 0>>
    end

    test "round-trips 32 random bytes" do
      bytes = :crypto.strong_rand_bytes(32)
      assert Base58.decode!(Base58.encode!(bytes)) == bytes
    end

    test "round-trips 32-byte key with leading zero byte" do
      bytes = <<0>> <> :crypto.strong_rand_bytes(31)
      encoded = Base58.encode!(bytes)
      assert String.starts_with?(encoded, "1")
      assert Base58.decode!(encoded) == bytes
    end

    test "raises on invalid character" do
      assert_raise ArgumentError, ~r/invalid character/, fn ->
        Base58.decode!("0OIl")
      end
    end
  end

  describe "encode!/1" do
    test "empty input → empty string" do
      assert Base58.encode!(<<>>) == ""
    end

    test "single zero byte → '1'" do
      assert Base58.encode!(<<0>>) == "1"
    end
  end
end
