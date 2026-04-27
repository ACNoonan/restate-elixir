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

  defmodule LongGreet do
    @moduledoc false
    alias Restate.Context

    def handle(ctx, name) do
      Context.set_state(ctx, "step", "started")
      Context.sleep(ctx, 10_000)
      Context.set_state(ctx, "step", "after_sleep")
      "hello #{name}"
    end
  end

  defp run(start, input, mfa, replay \\ []) do
    replay_frames =
      Enum.map(replay, fn msg -> %Restate.Protocol.Frame{type: 0, flags: 0, message: msg} end)

    {:ok, pid} = Invocation.start_link({start, input, replay_frames, mfa})
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

  describe "Restate.ProtocolError + related_command_*" do
    defmodule MismatchedHandler do
      alias Restate.Context

      def handle(ctx, _input) do
        Context.set_state(ctx, "k", "v")
        :ok
      end
    end

    defmodule TwoSetsThenBoom do
      alias Restate.Context

      def handle(ctx, _input) do
        Context.set_state(ctx, "a", 1)
        Context.set_state(ctx, "b", 2)
        raise "boom"
      end
    end

    test "journal mismatch (set_state vs recorded sleep) emits ErrorMessage{code: 570}" do
      replay = [%Pb.SleepCommandMessage{result_completion_id: 1, wake_up_time: 0}]

      assert [%Pb.ErrorMessage{} = err] =
               run(%Pb.StartMessage{}, nil, {MismatchedHandler, :handle, 2}, replay)

      assert err.code == 570
      assert err.message =~ "journal mismatch"
    end

    test "journal exhausted (set_state, no recorded entries during replay) emits 570" do
      # Force replay phase by including a notification (which alone won't put
      # us in :replaying — only commands do — so we include a fake recorded
      # SleepCommand to enter :replaying, then set_state mismatches against it).
      replay = [
        %Pb.SleepCommandMessage{result_completion_id: 1, wake_up_time: 0}
      ]

      assert [%Pb.ErrorMessage{code: 570}] =
               run(%Pb.StartMessage{}, nil, {MismatchedHandler, :handle, 2}, replay)
    end

    test "ErrorMessage carries related_command_index after the failing op" do
      assert [
               %Pb.SetStateCommandMessage{key: "a"},
               %Pb.SetStateCommandMessage{key: "b"},
               %Pb.ErrorMessage{} = err
             ] = run(%Pb.StartMessage{}, nil, {TwoSetsThenBoom, :handle, 2})

      # Two SetState commands processed (indexes 0 and 1) before raise.
      assert err.related_command_index == 1
      assert err.related_command_type == 0x0403
    end
  end

  describe "clear_state" do
    defmodule Clearer do
      alias Restate.Context

      def handle(ctx, _input) do
        Context.clear_state(ctx, "step")
        :ok
      end
    end

    test "emits ClearStateCommandMessage in :processing" do
      assert [
               %Pb.ClearStateCommandMessage{key: "step"},
               %Pb.OutputCommandMessage{},
               %Pb.EndMessage{}
             ] = run(%Pb.StartMessage{}, nil, {Clearer, :handle, 2})
    end

    test "consumed silently in :replaying — not re-emitted" do
      replay = [%Pb.ClearStateCommandMessage{key: "step"}]

      assert [%Pb.OutputCommandMessage{}, %Pb.EndMessage{}] =
               run(%Pb.StartMessage{}, nil, {Clearer, :handle, 2}, replay)
    end
  end

  describe "Restate.TerminalError" do
    defmodule TerminalRaiser do
      alias Restate.Context

      def handle(ctx, _input) do
        Context.set_state(ctx, "step", "started")
        raise Restate.TerminalError, message: "alice", code: 409
      end
    end

    test "raises produce OutputCommandMessage{failure} + End — not ErrorMessage" do
      assert [
               %Pb.SetStateCommandMessage{},
               %Pb.OutputCommandMessage{
                 result: {:failure, %Pb.Failure{code: 409, message: "alice"}}
               },
               %Pb.EndMessage{}
             ] = run(%Pb.StartMessage{}, nil, {TerminalRaiser, :handle, 2})
    end
  end

  describe "ctx.call" do
    defmodule Caller do
      alias Restate.Context

      def handle(ctx, _input) do
        result = Context.call(ctx, "Counter", "add", 5, key: "k1")
        %{got: result}
      end
    end

    test "first call: emits CallCommandMessage(2 cids) + Suspension(result cid)" do
      assert [
               %Pb.CallCommandMessage{
                 service_name: "Counter",
                 handler_name: "add",
                 key: "k1",
                 invocation_id_notification_idx: cid_invok,
                 result_completion_id: cid_result
               },
               %Pb.SuspensionMessage{waiting_completions: [cid_susp]}
             ] = run(%Pb.StartMessage{}, nil, {Caller, :handle, 2})

      assert cid_invok == 1
      assert cid_result == 2
      assert cid_susp == cid_result
    end

    test "replay with value notification: returns the result, continues" do
      replay = [
        %Pb.CallCommandMessage{
          service_name: "Counter",
          handler_name: "add",
          key: "k1",
          invocation_id_notification_idx: 1,
          result_completion_id: 2
        },
        %Pb.CallInvocationIdCompletionNotificationMessage{
          completion_id: 1,
          invocation_id: "inv_xyz"
        },
        %Pb.CallCompletionNotificationMessage{
          completion_id: 2,
          result: {:value, %Pb.Value{content: Jason.encode!(%{"oldValue" => 0, "newValue" => 5})}}
        }
      ]

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(%Pb.StartMessage{}, nil, {Caller, :handle, 2}, replay)

      assert Jason.decode!(out) == %{"got" => %{"oldValue" => 0, "newValue" => 5}}
    end

    test "replay with failure notification: raises Restate.TerminalError → OutputCommandMessage{failure}" do
      replay = [
        %Pb.CallCommandMessage{
          service_name: "Counter",
          handler_name: "add",
          key: "k1",
          invocation_id_notification_idx: 1,
          result_completion_id: 2
        },
        %Pb.CallCompletionNotificationMessage{
          completion_id: 2,
          result: {:failure, %Pb.Failure{code: 409, message: "callee said no"}}
        }
      ]

      assert [
               %Pb.OutputCommandMessage{
                 result: {:failure, %Pb.Failure{code: 409, message: "callee said no"}}
               },
               %Pb.EndMessage{}
             ] = run(%Pb.StartMessage{}, nil, {Caller, :handle, 2}, replay)
    end

    test "replay without result notification: re-suspends on result_completion_id" do
      replay = [
        %Pb.CallCommandMessage{
          service_name: "Counter",
          handler_name: "add",
          key: "k1",
          invocation_id_notification_idx: 1,
          result_completion_id: 2
        }
      ]

      assert [%Pb.SuspensionMessage{waiting_completions: [2]}] =
               run(%Pb.StartMessage{}, nil, {Caller, :handle, 2}, replay)
    end
  end

  describe "ctx.awakeable" do
    defmodule SelfAwait do
      alias Restate.Context

      def handle(ctx, _input) do
        {id, handle} = Context.awakeable(ctx)
        Context.complete_awakeable(ctx, id, %{value: 42})
        Context.await_awakeable(ctx, handle)
      end
    end

    test "awakeable id uses sign_1 prefix (V5 signal-id routing)" do
      assert [
               %Pb.CompleteAwakeableCommandMessage{awakeable_id: id},
               %Pb.SuspensionMessage{waiting_signals: [signal_id]}
             ] =
               run(
                 %Pb.StartMessage{id: <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11>>},
                 nil,
                 {SelfAwait, :handle, 2}
               )

      assert String.starts_with?(id, "sign_1")
      # First awakeable in any invocation must allocate signal_id 17 —
      # 1–16 are reserved for built-in signals (cancel, etc.) per
      # Restate's runtime convention.
      assert signal_id == 17
    end

    test "replay with signal notification: await returns the value" do
      # Mirrors what Restate sends on re-invocation after the
      # CompleteAwakeable was processed: a SignalNotification with
      # signal_id 17 carrying the resolution value.
      replay = [
        %Pb.CompleteAwakeableCommandMessage{
          awakeable_id: "sign_1<placeholder>",
          result: {:value, %Pb.Value{content: Jason.encode!(%{"value" => 42})}}
        },
        %Pb.SignalNotificationMessage{
          signal_id: {:idx, 17},
          result: {:value, %Pb.Value{content: Jason.encode!(%{"value" => 42})}}
        }
      ]

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] =
               run(
                 %Pb.StartMessage{id: <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11>>},
                 nil,
                 {SelfAwait, :handle, 2},
                 replay
               )

      assert Jason.decode!(out) == %{"value" => 42}
    end

    test "signal-id allocator is deterministic across replays" do
      # On the second invocation the journal contains a
      # SignalNotificationMessage with signal_id 17. The allocator
      # MUST still return 17 for the first awakeable on this run —
      # if it advanced past 17 (e.g. journal-max+1), the await
      # would deadlock waiting on a signal id that never fires.
      replay = [
        %Pb.CompleteAwakeableCommandMessage{
          awakeable_id: "sign_1<placeholder>",
          result: {:value, %Pb.Value{content: Jason.encode!(%{"value" => 42})}}
        },
        %Pb.SignalNotificationMessage{
          signal_id: {:idx, 17},
          result: {:value, %Pb.Value{content: Jason.encode!(%{"value" => 42})}}
        }
      ]

      # The replay completes — proving the deterministic allocation
      # produced 17 again. No further assertion needed; if the
      # allocator started at 18 we'd suspend forever and timeout.
      assert [%Pb.OutputCommandMessage{}, %Pb.EndMessage{}] =
               run(
                 %Pb.StartMessage{id: <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11>>},
                 nil,
                 {SelfAwait, :handle, 2},
                 replay
               )
    end
  end

  describe "ctx.send" do
    defmodule Sender do
      alias Restate.Context

      def handle(ctx, _input) do
        id = Context.send(ctx, "Counter", "add", 1, key: "k1")
        %{spawned: id}
      end
    end

    test "first send: emits OneWayCallCommandMessage + Suspension(invocation_id_idx)" do
      assert [
               %Pb.OneWayCallCommandMessage{
                 service_name: "Counter",
                 handler_name: "add",
                 key: "k1",
                 invocation_id_notification_idx: cid
               },
               %Pb.SuspensionMessage{waiting_completions: [cid_susp]}
             ] = run(%Pb.StartMessage{}, nil, {Sender, :handle, 2})

      assert cid == 1
      assert cid_susp == cid
    end

    test "replay with invocation_id notification: returns the id" do
      replay = [
        %Pb.OneWayCallCommandMessage{
          service_name: "Counter",
          handler_name: "add",
          key: "k1",
          invocation_id_notification_idx: 1
        },
        %Pb.CallInvocationIdCompletionNotificationMessage{
          completion_id: 1,
          invocation_id: "inv_abc"
        }
      ]

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(%Pb.StartMessage{}, nil, {Sender, :handle, 2}, replay)

      assert Jason.decode!(out) == %{"spawned" => "inv_abc"}
    end
  end

  describe "sleep + suspension (Week 3)" do
    test "first call: emits SetState, SleepCommand, then SuspensionMessage; no End" do
      assert [
               %Pb.SetStateCommandMessage{key: "step", value: %Pb.Value{content: started}},
               %Pb.SleepCommandMessage{result_completion_id: cid, wake_up_time: wake},
               %Pb.SuspensionMessage{waiting_completions: [cid_susp]}
             ] = run(%Pb.StartMessage{}, "world", {LongGreet, :handle, 2})

      assert Jason.decode!(started) == "started"
      assert cid == cid_susp
      assert is_integer(wake) and wake > 0
    end

    test "re-invocation with uncompleted sleep in journal: re-emits Suspension only" do
      replay = [
        %Pb.SetStateCommandMessage{key: "step", value: %Pb.Value{content: ~s("started")}},
        %Pb.SleepCommandMessage{result_completion_id: 1, wake_up_time: 0}
      ]

      start = %Pb.StartMessage{
        state_map: [%Pb.StartMessage.StateEntry{key: "step", value: ~s("started")}]
      }

      assert [%Pb.SuspensionMessage{waiting_completions: [1]}] =
               run(start, "world", {LongGreet, :handle, 2}, replay)
    end

    test "re-invocation with completed sleep: replays through, emits NEW post-sleep work + End" do
      replay = [
        %Pb.SetStateCommandMessage{key: "step", value: %Pb.Value{content: ~s("started")}},
        %Pb.SleepCommandMessage{result_completion_id: 1, wake_up_time: 0},
        %Pb.SleepCompletionNotificationMessage{completion_id: 1, void: %Pb.Void{}}
      ]

      start = %Pb.StartMessage{
        state_map: [%Pb.StartMessage.StateEntry{key: "step", value: ~s("started")}]
      }

      assert [
               %Pb.SetStateCommandMessage{key: "step", value: %Pb.Value{content: after_sleep}},
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(start, "world", {LongGreet, :handle, 2}, replay)

      assert Jason.decode!(after_sleep) == "after_sleep"
      assert Jason.decode!(out) == "hello world"
    end

    test "replayed SetState before the sleep is NOT re-emitted" do
      # The recorded SetState("started") must be consumed silently by the
      # state machine — only the post-sleep new work goes on the wire.
      replay = [
        %Pb.SetStateCommandMessage{key: "step", value: %Pb.Value{content: ~s("started")}},
        %Pb.SleepCommandMessage{result_completion_id: 1, wake_up_time: 0},
        %Pb.SleepCompletionNotificationMessage{completion_id: 1, void: %Pb.Void{}}
      ]

      messages =
        run(
          %Pb.StartMessage{
            state_map: [%Pb.StartMessage.StateEntry{key: "step", value: ~s("started")}]
          },
          "world",
          {LongGreet, :handle, 2},
          replay
        )

      set_states = Enum.filter(messages, &match?(%Pb.SetStateCommandMessage{}, &1))

      assert [%Pb.SetStateCommandMessage{value: %Pb.Value{content: only}}] = set_states
      assert Jason.decode!(only) == "after_sleep"
    end
  end
end
