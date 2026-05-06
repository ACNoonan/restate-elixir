defmodule Restate.ContextRandomTest do
  @moduledoc """
  Determinism tests for `Restate.Context.random_uniform/1,2`,
  `random_bytes/2`, and `random_uuid/1` (V6 protocol feature). Drives
  handlers via `Restate.Test.FakeRuntime`, which forwards `:random_seed`
  into `StartMessage.random_seed` exactly the way `restate-server`
  does on a V6-negotiated invocation.
  """
  use ExUnit.Case, async: true

  alias Restate.Test.FakeRuntime

  defmodule SeededHandler do
    @moduledoc false
    alias Restate.Context

    def random_float(ctx, _input), do: Context.random_uniform(ctx)
    def random_int(ctx, _input), do: Context.random_uniform(ctx, 1_000_000)
    def random_bytes(ctx, _input), do: Base.encode16(Context.random_bytes(ctx, 16))
    def random_uuid(ctx, _input), do: Context.random_uuid(ctx)

    def two_calls(ctx, _input) do
      a = Context.random_uniform(ctx, 1_000_000)
      b = Context.random_uniform(ctx, 1_000_000)
      [a, b]
    end
  end

  describe "with the same random_seed" do
    test "random_uniform/1 returns the same float across runs" do
      a = FakeRuntime.run({SeededHandler, :random_float, 2}, nil, random_seed: 42)
      b = FakeRuntime.run({SeededHandler, :random_float, 2}, nil, random_seed: 42)

      assert a.outcome == :value
      assert is_float(a.value)
      assert a.value == b.value
    end

    test "random_uniform/2 returns the same integer across runs" do
      a = FakeRuntime.run({SeededHandler, :random_int, 2}, nil, random_seed: 42)
      b = FakeRuntime.run({SeededHandler, :random_int, 2}, nil, random_seed: 42)

      assert a.value == b.value
    end

    test "random_bytes/2 returns the same bytes across runs" do
      a = FakeRuntime.run({SeededHandler, :random_bytes, 2}, nil, random_seed: 1234)
      b = FakeRuntime.run({SeededHandler, :random_bytes, 2}, nil, random_seed: 1234)

      assert a.value == b.value
    end

    test "random_uuid/1 returns the same UUID and v4-shaped" do
      a = FakeRuntime.run({SeededHandler, :random_uuid, 2}, nil, random_seed: 1234)
      b = FakeRuntime.run({SeededHandler, :random_uuid, 2}, nil, random_seed: 1234)

      assert a.value == b.value
      # Standard 8-4-4-4-12 hex with v4 in the 13th nibble and 8/9/a/b in the 17th.
      assert a.value =~
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    end

    test "two consecutive calls advance the RNG state" do
      a = FakeRuntime.run({SeededHandler, :two_calls, 2}, nil, random_seed: 99)
      [first, second] = a.value

      # The second call must consume more RNG state than the first;
      # otherwise the seed contract is broken (handler would always
      # see the same value).
      refute first == second
    end
  end

  describe "with a different random_seed" do
    test "random_uniform/2 produces a different value" do
      a = FakeRuntime.run({SeededHandler, :random_int, 2}, nil, random_seed: 1)
      b = FakeRuntime.run({SeededHandler, :random_int, 2}, nil, random_seed: 2)

      refute a.value == b.value
    end
  end

  describe "without a random_seed (V5 fallback)" do
    test "random_uniform/2 still returns a value (non-deterministic)" do
      # No :random_seed opt — defaults to 0 — Invocation skips :rand.seed.
      # We don't assert determinism here because there isn't any; we
      # only assert the API is still callable so V5 deployments don't
      # break by upgrading the SDK.
      result = FakeRuntime.run({SeededHandler, :random_int, 2}, nil)
      assert result.outcome == :value
      assert is_integer(result.value) and result.value in 1..1_000_000
    end
  end
end
