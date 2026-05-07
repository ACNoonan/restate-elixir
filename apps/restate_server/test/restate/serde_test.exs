defmodule Restate.SerdeTest do
  # Some tests mutate the :restate_server :serde app env and need to
  # serialize against other tests that read it.
  use ExUnit.Case, async: false

  alias Restate.Serde

  describe "Restate.Serde.Json (default impl)" do
    test "encodes/decodes a map round-trip" do
      term = %{"counter" => 1, "name" => "world"}
      assert term |> Serde.Json.encode() |> Serde.Json.decode() == term
    end

    test "encodes/decodes lists, ints, floats, bools, nil" do
      for term <- [[1, 2, 3], 42, 3.14, true, false, nil] do
        assert term |> Serde.Json.encode() |> Serde.Json.decode() == term
      end
    end

    test "encodes a string by quoting it on the wire" do
      assert Serde.Json.encode("hello") == ~S("hello")
      assert Serde.Json.decode(~S("hello")) == "hello"
    end

    test "decode(\"\") returns nil — Restate's no-value convention" do
      assert Serde.Json.decode("") == nil
    end

    test "atom keys encode as strings; decoded keys come back as binaries" do
      assert %{counter: 1} |> Serde.Json.encode() |> Serde.Json.decode() == %{"counter" => 1}
    end
  end

  describe "Restate.Serde dispatcher" do
    test "default impl is Restate.Serde.Json" do
      # Don't mutate config; just probe.
      assert Serde.impl() == Serde.Json
    end

    test "encode/1 forwards to the configured impl" do
      assert Serde.encode(%{"k" => "v"}) == ~S({"k":"v"})
    end

    test "decode/1 forwards to the configured impl" do
      assert Serde.decode(~S({"k":"v"})) == %{"k" => "v"}
      assert Serde.decode("") == nil
    end
  end

  describe "swappable impl via :restate_server :serde app env" do
    defmodule TaggingSerde do
      # Sentinel impl used to prove the dispatcher reads app env on
      # every call and that handler I/O round-trips through whatever
      # the user configures. Encodes as `"::tagged::" <> Jason.encode!(term)`,
      # decodes by stripping the prefix.
      @behaviour Restate.Serde

      @prefix "::tagged::"

      @impl true
      def encode(term), do: @prefix <> Jason.encode!(term)

      @impl true
      def decode(""), do: nil
      def decode(@prefix <> rest), do: Jason.decode!(rest)
      def decode(_), do: raise("TaggingSerde decoded a non-tagged binary")
    end

    setup do
      original = Application.get_env(:restate_server, :serde)
      Application.put_env(:restate_server, :serde, TaggingSerde)

      on_exit(fn ->
        if original do
          Application.put_env(:restate_server, :serde, original)
        else
          Application.delete_env(:restate_server, :serde)
        end
      end)

      :ok
    end

    test "Serde.impl/0 reflects the app env" do
      assert Serde.impl() == TaggingSerde
    end

    test "encode/decode round-trip via the swapped impl" do
      term = %{"hello" => "world"}
      encoded = Serde.encode(term)

      assert String.starts_with?(encoded, "::tagged::"),
             "Encoded payload should carry the tagging prefix when the swapped impl is active"

      assert Serde.decode(encoded) == term
    end

    test "Restate.Context.set_state/get_state path uses the swapped serde end-to-end" do
      # FakeRuntime drives a real Invocation GenServer with a real
      # handler — exercises the same code path the HTTP endpoint
      # would, just without the wire layer.
      defmodule SerdeRoundTripHandler do
        alias Restate.Context
        def write_then_read(%Context{} = ctx, _input) do
          Context.set_state(ctx, "key", %{"hi" => "there"})
          Context.get_state(ctx, "key")
        end
      end

      result =
        Restate.Test.FakeRuntime.run(
          {SerdeRoundTripHandler, :write_then_read, 2},
          nil
        )

      assert result.outcome == :value
      # Round-trip: set_state encodes via TaggingSerde, get_state on
      # the same ctx pulls bytes out of state_map and decodes via
      # TaggingSerde — what we get back must equal what we put in.
      assert result.value == %{"hi" => "there"}

      # And the journaled bytes must carry the tagging prefix —
      # proves the swapped serde was actually involved.
      assert Map.fetch!(result.state, "key") =~ "::tagged::"
    end

    test "{:raw, bytes} opt-out skips the configured encoder" do
      # The opt-out's purpose: callers that already hold pre-encoded
      # wire bytes (matching the *configured serde's* expected
      # format) can skip the encode pass. Used by the conformance
      # Proxy handler to forward opaque payloads end-to-end.
      #
      # We test this at `encode_parameter/1`'s level by writing a
      # `ctx.run` whose result is `{:raw, json_bytes}` — the bytes
      # have to be valid for the receiving serde because they round-
      # trip through `decode_response/1` on replay. Here we hand it
      # JSON bytes that the TaggingSerde happens to recognise as
      # valid (carries the prefix); the encoder bypasses it, the
      # decoder accepts it.
      defmodule RawOptOutHandler do
        alias Restate.Context

        def echo_raw(%Context{} = ctx, _input) do
          # Pre-tagged bytes: TaggingSerde.decode will succeed.
          Context.run(ctx, fn -> {:raw, "::tagged::" <> Jason.encode!(%{"x" => 1})} end)
        end
      end

      result =
        Restate.Test.FakeRuntime.run(
          {RawOptOutHandler, :echo_raw, 2},
          nil
        )

      assert result.outcome == :value
      assert result.value == %{"x" => 1}
    end
  end
end
