defmodule Restate.Test.FakeRuntimeTest do
  use ExUnit.Case, async: true

  alias Restate.Test.FakeRuntime

  defmodule Handlers do
    @moduledoc false
    alias Restate.Context

    def pure(_ctx, input), do: %{"echo" => input}

    def increment(ctx, _input) do
      n = Context.get_state(ctx, "counter") || 0
      Context.set_state(ctx, "counter", n + 1)
      "hello #{n + 1}"
    end

    def clears(ctx, _input) do
      Context.set_state(ctx, "tmp", 1)
      Context.clear_state(ctx, "stale")
      "ok"
    end

    def naps(ctx, _input) do
      Context.sleep(ctx, 100)
      Context.sleep(ctx, 200)
      "awake"
    end

    def runs(ctx, _input) do
      Context.run(ctx, fn -> "ai-result" end)
    end

    def runs_then_state(ctx, _input) do
      result = Context.run(ctx, fn -> "computed" end)
      Context.set_state(ctx, "last", result)
      result
    end

    def lazy_get(ctx, _input) do
      # With partial_state=true, get_state on a missing key triggers
      # a GetLazyStateCommand round-trip; on a present key it serves
      # eagerly. Round-trip both to exercise the path.
      Context.get_state(ctx, "lazy_key")
    end

    def calls_other(ctx, _input) do
      Context.call(ctx, "Other", "compute", %{"x" => 1})
    end

    def raises_terminal(_ctx, _input) do
      raise %Restate.TerminalError{code: 422, message: "bad input"}
    end

    def raises_generic(_ctx, _input), do: raise("kaboom")

    def workflow_blocks(ctx, _input) do
      Context.get_promise(ctx, "result")
    end

    def loops_forever(ctx, _input) do
      Context.sleep(ctx, 1)
      loops_forever(ctx, nil)
    end
  end

  describe "pure handlers" do
    test "no journal, terminal :value" do
      result = FakeRuntime.run({Handlers, :pure, 2}, %{"name" => "world"})

      assert result.outcome == :value
      assert result.value == %{"echo" => %{"name" => "world"}}
      assert result.iterations == 1
      assert result.state == %{}
    end

    test "raises_terminal → outcome :terminal_failure with TerminalError" do
      result = FakeRuntime.run({Handlers, :raises_terminal, 2})

      assert result.outcome == :terminal_failure
      assert %Restate.TerminalError{code: 422, message: "bad input"} = result.value
    end

    test "raises generic exception → outcome :error" do
      result = FakeRuntime.run({Handlers, :raises_generic, 2})

      assert result.outcome == :error
    end
  end

  describe "state operations" do
    test "set_state with eager initial state" do
      result =
        FakeRuntime.run({Handlers, :increment, 2}, nil, state: %{"counter" => Jason.encode!(2)})

      assert result.outcome == :value
      assert result.value == "hello 3"
      # State on the wire is JSON-encoded bytes; the SDK encodes
      # whatever term the handler passes to set_state.
      assert result.state["counter"] == "3"
    end

    test "set_state from empty initial state" do
      result = FakeRuntime.run({Handlers, :increment, 2})

      assert result.outcome == :value
      assert result.value == "hello 1"
      assert result.state["counter"] == "1"
    end

    test "clear_state removes the key from final state" do
      result =
        FakeRuntime.run({Handlers, :clears, 2}, nil,
          state: %{"stale" => Jason.encode!("old"), "keep" => Jason.encode!("yes")}
        )

      assert result.outcome == :value
      refute Map.has_key?(result.state, "stale")
      assert result.state["keep"] == Jason.encode!("yes")
      assert result.state["tmp"] == "1"
    end

    test "lazy state served from initial :state opt" do
      result =
        FakeRuntime.run({Handlers, :lazy_get, 2}, nil,
          partial_state: true,
          state: %{"lazy_key" => Jason.encode!("found")}
        )

      assert result.outcome == :value
      assert result.value == "found"
      # Two iterations: one to emit the GetLazyState + suspend, one to
      # consume the synthesised completion and terminate.
      assert result.iterations == 2
    end

    test "lazy state returns nil for missing key" do
      result =
        FakeRuntime.run({Handlers, :lazy_get, 2}, nil, partial_state: true, state: %{})

      assert result.outcome == :value
      assert result.value == nil
    end
  end

  describe "ctx.sleep" do
    test "sleeps complete instantly" do
      result = FakeRuntime.run({Handlers, :naps, 2})

      assert result.outcome == :value
      assert result.value == "awake"
      # Two sleeps → two suspend-resume cycles + the final terminating
      # iteration = 3.
      assert result.iterations == 3
    end
  end

  describe "ctx.run" do
    test "uses the SDK's proposed value on resume" do
      result = FakeRuntime.run({Handlers, :runs, 2})

      assert result.outcome == :value
      assert result.value == "ai-result"
      assert map_size(result.run_completions) == 1
    end

    test "ctx.run followed by set_state" do
      result = FakeRuntime.run({Handlers, :runs_then_state, 2})

      assert result.outcome == :value
      assert result.value == "computed"
      assert result.state["last"] == Jason.encode!("computed")
      # Wire bytes are JSON-encoded; the encoded form of "computed" is
      # `"\"computed\""`. The cleanest way to match that is to compare
      # against the same `Jason.encode!/1` invocation.
    end
  end

  describe "ctx.call" do
    test "uses :call_responses static value" do
      result =
        FakeRuntime.run({Handlers, :calls_other, 2}, nil,
          call_responses: %{{"Other", "compute"} => 42}
        )

      assert result.outcome == :value
      assert result.value == 42
    end

    test "uses :call_responses function with the request bytes" do
      result =
        FakeRuntime.run({Handlers, :calls_other, 2}, nil,
          call_responses: %{
            {"Other", "compute"} => fn params ->
              %{"got" => Jason.decode!(params)}
            end
          }
        )

      assert result.outcome == :value
      assert result.value == %{"got" => %{"x" => 1}}
    end

    test "missing :call_responses raises with helpful error" do
      assert_raise RuntimeError, ~r/no response was provided.*Other.*compute/s, fn ->
        FakeRuntime.run({Handlers, :calls_other, 2})
      end
    end
  end

  describe "unsupported v0 surfaces raise helpfully" do
    test "workflow promise" do
      assert_raise RuntimeError, ~r/get_promise.*not yet supported/, fn ->
        FakeRuntime.run({Handlers, :workflow_blocks, 2})
      end
    end
  end

  describe "max-iterations safety" do
    test "infinite-loop handler hits the cap" do
      assert_raise RuntimeError, ~r/within 5 suspend-resume iterations/, fn ->
        FakeRuntime.run({Handlers, :loops_forever, 2}, nil, max_iterations: 5)
      end
    end
  end
end
