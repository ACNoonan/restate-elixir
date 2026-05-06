defmodule Restate.TelemetryTest do
  # async: false because the registry uses :persistent_term and the
  # :telemetry handler is process-global.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Dev.Restate.Service.Protocol, as: Pb
  alias Restate.Protocol.Framer
  alias Restate.Server.{Endpoint, Registry}

  defmodule Handlers do
    @moduledoc false
    alias Restate.Context

    def ok(_ctx, _input), do: "ok"

    def boom(_ctx, _input), do: raise("kaboom")

    def terminal(_ctx, _input),
      do: raise(%Restate.TerminalError{code: 422, message: "nope"})

    def nap(ctx, _input), do: Context.sleep(ctx, 5_000)

    def set_one(ctx, _input) do
      Context.set_state(ctx, "k", "v")
      "done"
    end
  end

  @opts Endpoint.init([])

  setup do
    Registry.reset()

    Registry.register_service(%{
      name: "T",
      type: :service,
      handlers: [
        %{name: "ok", type: :exclusive, mfa: {Handlers, :ok, 2}},
        %{name: "boom", type: :exclusive, mfa: {Handlers, :boom, 2}},
        %{name: "terminal", type: :exclusive, mfa: {Handlers, :terminal, 2}},
        %{name: "nap", type: :exclusive, mfa: {Handlers, :nap, 2}},
        %{name: "set_one", type: :exclusive, mfa: {Handlers, :set_one, 2}}
      ]
    })

    test_pid = self()
    handler_id = :"telemetry_test_#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:restate, :invocation, :start],
        [:restate, :invocation, :stop],
        [:restate, :invocation, :exception],
        [:restate, :invocation, :replay_complete],
        [:restate, :invocation, :journal_mismatch]
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  describe "span events" do
    test ":start fires before :stop and both carry service/handler" do
      invoke("ok")

      assert_receive {:telemetry, [:restate, :invocation, :start], start_meas,
                      %{service: "T", handler: "ok"}}

      assert is_integer(start_meas.system_time)
      assert is_integer(start_meas.monotonic_time)

      assert_receive {:telemetry, [:restate, :invocation, :stop], stop_meas,
                      %{service: "T", handler: "ok", outcome: :value} = stop_meta}

      assert is_integer(stop_meas.duration) and stop_meas.duration >= 0
      assert stop_meta.response_bytes > 0
    end

    test "outcome :terminal_failure when handler raises Restate.TerminalError" do
      invoke("terminal")

      assert_receive {:telemetry, [:restate, :invocation, :stop], _,
                      %{outcome: :terminal_failure}}
    end

    test "outcome :error when handler raises a generic exception" do
      invoke("boom")

      assert_receive {:telemetry, [:restate, :invocation, :stop], _,
                      %{outcome: :error}}
    end

    test "outcome :suspended when handler blocks on a completion" do
      invoke("nap")

      assert_receive {:telemetry, [:restate, :invocation, :stop], _,
                      %{outcome: :suspended}}
    end
  end

  describe ":replay_complete" do
    test "fires when the handler exhausts a recorded journal" do
      # `set_one` calls Context.set_state once. We feed it one recorded
      # SetStateCommandMessage so replay drains and the phase flips
      # mid-handler. Without a recorded journal, advance_phase isn't
      # called from a `:replaying` state and the event doesn't fire.
      replay = [
        %Pb.SetStateCommandMessage{key: "k", value: %Pb.Value{content: "v"}}
      ]

      invoke("set_one", replay: replay)

      assert_receive {:telemetry, [:restate, :invocation, :replay_complete], measurements,
                      %{service: "T", handler: "set_one"}}

      assert measurements.replayed_commands == 1
      assert is_integer(measurements.monotonic_time)
    end

    test "does not fire for a fresh invocation (empty journal)" do
      invoke("ok")

      refute_receive {:telemetry, [:restate, :invocation, :replay_complete], _, _}, 50
    end
  end

  describe ":journal_mismatch" do
    test "fires when handler asks for a different command than recorded" do
      # Handler will call Context.set_state, but recorded journal next
      # entry is SleepCommandMessage. State machine raises 570.
      replay = [
        %Pb.SleepCommandMessage{wake_up_time: 0, result_completion_id: 1}
      ]

      invoke("set_one", replay: replay)

      assert_receive {:telemetry, [:restate, :invocation, :journal_mismatch], _,
                      %{service: "T", handler: "set_one", code: 570} = meta}

      assert is_binary(meta.message)
      assert is_integer(meta.command_index)

      assert_receive {:telemetry, [:restate, :invocation, :stop], _,
                      %{outcome: :journal_mismatch}}
    end
  end

  defp invoke(handler, opts \\ []) do
    body = invocation_body(opts)

    :post
    |> conn("/invoke/T/#{handler}", body)
    |> put_req_header("content-type", "application/vnd.restate.invocation.v5")
    |> Endpoint.call(@opts)
  end

  defp invocation_body(opts) do
    replay = Keyword.get(opts, :replay, [])

    start = %Pb.StartMessage{
      id: <<0, 1, 2, 3>>,
      debug_id: "test",
      known_entries: 1
    }

    input = %Pb.InputCommandMessage{value: %Pb.Value{content: Jason.encode!(nil)}}

    framed_replay = Enum.map_join(replay, <<>>, &Framer.encode/1)

    Framer.encode(start) <> Framer.encode(input) <> framed_replay
  end
end
