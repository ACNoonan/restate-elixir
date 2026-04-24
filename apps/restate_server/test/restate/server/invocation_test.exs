defmodule Restate.Server.InvocationTest do
  use ExUnit.Case, async: true

  alias Dev.Restate.Service.Protocol, as: Pb
  alias Restate.Protocol.Framer
  alias Restate.Server.Invocation

  defmodule Counter do
    @moduledoc false
    alias Restate.Context

    def handle(ctx, _input) do
      n = (Context.get_state(ctx, "counter") || 0) + 1
      Context.set_state(ctx, "counter", n)
      "hello #{n}"
    end

    def boom(_ctx, _input), do: raise("kaboom")

    def echo_input(_ctx, input), do: input
  end

  defp run(start, input, mfa) do
    {:ok, pid} = Invocation.start_link({start, input, mfa})
    body = Invocation.await_response(pid)
    {:ok, frames, ""} = Framer.decode_all(body)
    Enum.map(frames, & &1.message)
  end

  describe "happy path" do
    test "first call: counter starts at 1, emits SetState(1) + Output + End" do
      start = %Pb.StartMessage{}

      assert [
               %Pb.SetStateCommandMessage{key: "counter", value: %Pb.Value{content: "1"}},
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(start, nil, {Counter, :handle, 2})

      assert Jason.decode!(out) == "hello 1"
    end

    test "second call: state_map seeds counter, emits SetState(2)" do
      start = %Pb.StartMessage{
        state_map: [%Pb.StartMessage.StateEntry{key: "counter", value: "1"}]
      }

      assert [
               %Pb.SetStateCommandMessage{key: "counter", value: %Pb.Value{content: "2"}},
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(start, nil, {Counter, :handle, 2})

      assert Jason.decode!(out) == "hello 2"
    end

    test "input value is passed through to the handler" do
      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(%Pb.StartMessage{}, %{"name" => "world"}, {Counter, :echo_input, 2})

      assert Jason.decode!(out) == %{"name" => "world"}
    end
  end

  describe "handler crash" do
    test "raises produce ErrorMessage with code 500 — and no End frame" do
      [%Pb.ErrorMessage{} = err] = run(%Pb.StartMessage{}, nil, {Counter, :boom, 2})

      assert err.code == 500
      assert err.message =~ "kaboom"
      assert err.stacktrace != ""
    end

    test "any state-mutating commands made before the raise are still emitted" do
      defmodule HalfWay do
        alias Restate.Context

        def handle(ctx, _input) do
          Context.set_state(ctx, "step", "started")
          raise "stop"
        end
      end

      assert [
               %Pb.SetStateCommandMessage{key: "step"},
               %Pb.ErrorMessage{}
             ] = run(%Pb.StartMessage{}, nil, {HalfWay, :handle, 2})
    end
  end
end
