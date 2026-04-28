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
               %Pb.SuspensionMessage{waiting_signals: signals}
             ] =
               run(
                 %Pb.StartMessage{id: <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11>>},
                 nil,
                 {SelfAwait, :handle, 2}
               )

      assert String.starts_with?(id, "sign_1")
      # First awakeable in any invocation must allocate signal_id 17 —
      # 1–16 are reserved for built-in signals (cancel, etc.) per
      # Restate's runtime convention. Cancel-signal-id 1 is also listed
      # so the runtime can interrupt this wait if the invocation is
      # killed.
      assert 17 in signals
      assert 1 in signals
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

  describe "cancellation (built-in CANCEL signal, signal_id = 1)" do
    defmodule Sleeper do
      alias Restate.Context

      def handle(ctx, _input) do
        Context.set_state(ctx, "step", "started")
        Context.sleep(ctx, 10_000)
        Context.set_state(ctx, "step", "after_sleep")
        :ok
      end
    end

    defmodule Awaiter do
      alias Restate.Context

      def handle(ctx, _input) do
        {_id, handle} = Context.awakeable(ctx)
        Context.await_awakeable(ctx, handle)
      end
    end

    defmodule Caller2 do
      alias Restate.Context

      def handle(ctx, _input) do
        Context.call(ctx, "Counter", "add", 5, key: "k1")
      end
    end

    defmodule Cleanup do
      alias Restate.Context

      def handle(ctx, _input) do
        try do
          Context.sleep(ctx, 10_000)
        rescue
          _ in Restate.TerminalError ->
            Context.set_state(ctx, "cleaned_up", true)
            reraise Restate.TerminalError, [code: 409, message: "cancelled"], __STACKTRACE__
        end
      end
    end

    defmodule Canceller do
      alias Restate.Context

      def handle(ctx, _input) do
        Context.cancel_invocation(ctx, "inv_target_xyz")
        :ok
      end
    end

    test "cancel signal during sleep replay: raises terminal 409, no Suspension" do
      replay = [
        %Pb.SetStateCommandMessage{key: "step", value: %Pb.Value{content: ~s("started")}},
        %Pb.SleepCommandMessage{result_completion_id: 1, wake_up_time: 0},
        %Pb.SignalNotificationMessage{
          signal_id: {:idx, 1},
          result: {:void, %Pb.Void{}}
        }
      ]

      start = %Pb.StartMessage{
        state_map: [%Pb.StartMessage.StateEntry{key: "step", value: ~s("started")}]
      }

      assert [
               %Pb.OutputCommandMessage{
                 result: {:failure, %Pb.Failure{code: 409, message: "cancelled"}}
               },
               %Pb.EndMessage{}
             ] = run(start, nil, {Sleeper, :handle, 2}, replay)
    end

    test "completion-already-present beats cancel: sleep returns normally, then handler finishes" do
      # Java's semantic: cancel only raises when the await would
      # otherwise block. If the SleepCompletion is already in the
      # journal, return it and let the handler proceed; cancel will
      # fire at the next still-blocking op (or, if there isn't one,
      # the handler runs to completion). This is what makes
      # cancel propagation through a call tree work — without it, the
      # outer handler can't replay past its first awakeable to even
      # reach the inner ctx.call site.
      replay = [
        %Pb.SetStateCommandMessage{key: "step", value: %Pb.Value{content: ~s("started")}},
        %Pb.SleepCommandMessage{result_completion_id: 1, wake_up_time: 0},
        %Pb.SleepCompletionNotificationMessage{completion_id: 1, void: %Pb.Void{}},
        %Pb.SignalNotificationMessage{
          signal_id: {:idx, 1},
          result: {:void, %Pb.Void{}}
        }
      ]

      start = %Pb.StartMessage{
        state_map: [%Pb.StartMessage.StateEntry{key: "step", value: ~s("started")}]
      }

      # Sleep returns, then the second SetState fires, then the handler
      # returns :ok. No 409 raised because there's no remaining
      # blocking op for cancel to interrupt.
      assert [
               %Pb.SetStateCommandMessage{key: "step", value: %Pb.Value{content: after_sleep}},
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{}}},
               %Pb.EndMessage{}
             ] = run(start, nil, {Sleeper, :handle, 2}, replay)

      assert Jason.decode!(after_sleep) == "after_sleep"
    end

    test "user signal present + cancel: await returns the value (cancel parks for next blocking op)" do
      replay = [
        %Pb.SignalNotificationMessage{
          signal_id: {:idx, 17},
          result: {:value, %Pb.Value{content: Jason.encode!(%{"value" => 42})}}
        },
        %Pb.SignalNotificationMessage{
          signal_id: {:idx, 1},
          result: {:void, %Pb.Void{}}
        }
      ]

      # Awaiter has just one await — it returns the value and the
      # handler completes normally.
      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] =
               run(
                 %Pb.StartMessage{id: <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11>>},
                 nil,
                 {Awaiter, :handle, 2},
                 replay
               )

      assert Jason.decode!(out) == %{"value" => 42}
    end

    test "ctx.call result present + cancel: returns the result (cancel parks)" do
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
          result: {:value, %Pb.Value{content: Jason.encode!(%{"newValue" => 5})}}
        },
        %Pb.SignalNotificationMessage{
          signal_id: {:idx, 1},
          result: {:void, %Pb.Void{}}
        }
      ]

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(%Pb.StartMessage{}, nil, {Caller2, :handle, 2}, replay)

      assert Jason.decode!(out) == %{"newValue" => 5}
    end

    test "cancel propagates to outstanding ctx.call: emits SendSignal(idx=1) to callee" do
      # The call's invocation_id is in the journal but its result is
      # NOT — that's the "outstanding call" shape. On replay we see
      # the cancel signal, look up the callee's id from the
      # CallInvocationId notification, and emit a
      # SendSignalCommandMessage{idx: 1} so the callee gets cancelled
      # too. Restate's runtime does not auto-cascade cancel through
      # the call tree, so this is what makes "kill propagates" actually
      # work.
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
          invocation_id: "inv_callee_xyz"
        },
        %Pb.SignalNotificationMessage{
          signal_id: {:idx, 1},
          result: {:void, %Pb.Void{}}
        }
      ]

      assert [
               %Pb.SendSignalCommandMessage{
                 target_invocation_id: "inv_callee_xyz",
                 signal_id: {:idx, 1},
                 result: {:void, %Pb.Void{}}
               },
               %Pb.OutputCommandMessage{
                 result: {:failure, %Pb.Failure{code: 409, message: "cancelled"}}
               },
               %Pb.EndMessage{}
             ] = run(%Pb.StartMessage{}, nil, {Caller2, :handle, 2}, replay)
    end

    test "rescue Restate.TerminalError lets the handler do cleanup before terminating" do
      # Mirrors the Java behaviour: cancel is a regular TerminalException at
      # the await site, so handlers can `try/rescue` to release locks /
      # checkpoint state before the invocation ends.
      replay = [
        %Pb.SleepCommandMessage{result_completion_id: 1, wake_up_time: 0},
        %Pb.SignalNotificationMessage{
          signal_id: {:idx, 1},
          result: {:void, %Pb.Void{}}
        }
      ]

      assert [
               %Pb.SetStateCommandMessage{
                 key: "cleaned_up",
                 value: %Pb.Value{content: ~s(true)}
               },
               %Pb.OutputCommandMessage{
                 result: {:failure, %Pb.Failure{code: 409, message: "cancelled"}}
               },
               %Pb.EndMessage{}
             ] = run(%Pb.StartMessage{}, nil, {Cleanup, :handle, 2}, replay)
    end

    test "Context.cancel_invocation/2 emits SendSignalCommandMessage{idx: 1, void}" do
      assert [
               %Pb.SendSignalCommandMessage{
                 target_invocation_id: "inv_target_xyz",
                 signal_id: {:idx, 1},
                 result: {:void, %Pb.Void{}}
               },
               %Pb.OutputCommandMessage{},
               %Pb.EndMessage{}
             ] = run(%Pb.StartMessage{}, nil, {Canceller, :handle, 2})
    end

    test "SendSignal in :replaying is consumed silently — not re-emitted" do
      replay = [
        %Pb.SendSignalCommandMessage{
          target_invocation_id: "inv_target_xyz",
          signal_id: {:idx, 1},
          result: {:void, %Pb.Void{}}
        }
      ]

      assert [%Pb.OutputCommandMessage{}, %Pb.EndMessage{}] =
               run(%Pb.StartMessage{}, nil, {Canceller, :handle, 2}, replay)
    end
  end

  describe "Awaitable combinators (Awaitable.any / .all / .await)" do
    alias Restate.Awaitable

    defmodule AnyTimerOrAwakeable do
      alias Restate.Context

      def handle(ctx, _input) do
        timer = Context.timer(ctx, 100)
        {_id, awakeable} = Context.awakeable(ctx)
        # `any/2` returns `{index, value}` — JSON-encode as a list so
        # the test can match on it through Jason.
        {idx, value} = Awaitable.any(ctx, [awakeable, timer])
        [idx, value]
      end
    end

    defmodule AllTimers do
      alias Restate.Context

      def handle(ctx, _input) do
        t1 = Context.timer(ctx, 50)
        t2 = Context.timer(ctx, 100)
        Awaitable.all(ctx, [t1, t2])
      end
    end

    defmodule AwaitOneTimer do
      alias Restate.Context

      def handle(ctx, _input) do
        t = Context.timer(ctx, 100)
        Awaitable.await(ctx, t)
      end
    end

    test "Awaitable.any: emits Suspension with union of completion + signal ids on first run" do
      assert [
               %Pb.SleepCommandMessage{result_completion_id: timer_cid},
               %Pb.SuspensionMessage{
                 waiting_completions: comps,
                 waiting_signals: sigs
               }
             ] =
               run(
                 %Pb.StartMessage{id: <<1, 2, 3>>},
                 nil,
                 {AnyTimerOrAwakeable, :handle, 2}
               )

      assert timer_cid == 1
      # awakeable allocates signal_id 17. Suspension lists timer's cid
      # AND signal 17 AND cancel-signal 1.
      assert comps == [timer_cid]
      assert 17 in sigs
      # Cancel signal id 1 always present.
      assert 1 in sigs
    end

    test "Awaitable.any: returns {0, value} when first handle (awakeable) is in journal" do
      replay = [
        %Pb.SleepCommandMessage{result_completion_id: 1, wake_up_time: 0},
        %Pb.SignalNotificationMessage{
          signal_id: {:idx, 17},
          result: {:value, %Pb.Value{content: Jason.encode!("hello")}}
        }
      ]

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] =
               run(
                 %Pb.StartMessage{id: <<1, 2, 3>>},
                 nil,
                 {AnyTimerOrAwakeable, :handle, 2},
                 replay
               )

      # Awakeable is index 0 in the input list, value is "hello".
      assert Jason.decode!(out) == [0, "hello"]
    end

    test "Awaitable.any: returns {1, :ok} when timer (index 1) fires first" do
      replay = [
        %Pb.SleepCommandMessage{result_completion_id: 1, wake_up_time: 0},
        %Pb.SleepCompletionNotificationMessage{completion_id: 1, void: %Pb.Void{}}
      ]

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] =
               run(
                 %Pb.StartMessage{id: <<1, 2, 3>>},
                 nil,
                 {AnyTimerOrAwakeable, :handle, 2},
                 replay
               )

      # Timer is index 1, sleep returns "ok" (atom serializes to that string).
      assert Jason.decode!(out) == [1, "ok"]
    end

    test "Awaitable.all: emits two SleepCommands then suspends on both completion ids" do
      assert [
               %Pb.SleepCommandMessage{result_completion_id: cid1},
               %Pb.SleepCommandMessage{result_completion_id: cid2},
               %Pb.SuspensionMessage{
                 waiting_completions: comps,
                 waiting_signals: sigs
               }
             ] = run(%Pb.StartMessage{}, nil, {AllTimers, :handle, 2})

      assert cid1 == 1
      assert cid2 == 2
      assert Enum.sort(comps) == [1, 2]
      assert sigs == [1]
    end

    test "Awaitable.all: returns list of values when all completions are in the journal" do
      replay = [
        %Pb.SleepCommandMessage{result_completion_id: 1, wake_up_time: 0},
        %Pb.SleepCommandMessage{result_completion_id: 2, wake_up_time: 0},
        %Pb.SleepCompletionNotificationMessage{completion_id: 1, void: %Pb.Void{}},
        %Pb.SleepCompletionNotificationMessage{completion_id: 2, void: %Pb.Void{}}
      ]

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(%Pb.StartMessage{}, nil, {AllTimers, :handle, 2}, replay)

      # Two timers — sleep returns :ok (encodes as "ok").
      assert Jason.decode!(out) == ["ok", "ok"]
    end

    test "Awaitable.all: only one completion present → suspends on the missing one" do
      replay = [
        %Pb.SleepCommandMessage{result_completion_id: 1, wake_up_time: 0},
        %Pb.SleepCommandMessage{result_completion_id: 2, wake_up_time: 0},
        %Pb.SleepCompletionNotificationMessage{completion_id: 1, void: %Pb.Void{}}
      ]

      assert [
               %Pb.SuspensionMessage{
                 waiting_completions: [2],
                 waiting_signals: [1]
               }
             ] = run(%Pb.StartMessage{}, nil, {AllTimers, :handle, 2}, replay)
    end

    test "Awaitable.await: single-handle equivalent of all([h]), unwraps the list" do
      replay = [
        %Pb.SleepCommandMessage{result_completion_id: 1, wake_up_time: 0},
        %Pb.SleepCompletionNotificationMessage{completion_id: 1, void: %Pb.Void{}}
      ]

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(%Pb.StartMessage{}, nil, {AwaitOneTimer, :handle, 2}, replay)

      assert Jason.decode!(out) == "ok"
    end

    test "Awaitable.any: cancel during all-pending raises 409" do
      replay = [
        %Pb.SleepCommandMessage{result_completion_id: 1, wake_up_time: 0},
        %Pb.SignalNotificationMessage{
          signal_id: {:idx, 1},
          result: {:void, %Pb.Void{}}
        }
      ]

      assert [
               %Pb.OutputCommandMessage{
                 result: {:failure, %Pb.Failure{code: 409, message: "cancelled"}}
               },
               %Pb.EndMessage{}
             ] =
               run(
                 %Pb.StartMessage{id: <<1, 2, 3>>},
                 nil,
                 {AnyTimerOrAwakeable, :handle, 2},
                 replay
               )
    end

    test "Awaitable.any: completion present + cancel → returns the completion (cancel parks)" do
      replay = [
        %Pb.SleepCommandMessage{result_completion_id: 1, wake_up_time: 0},
        %Pb.SleepCompletionNotificationMessage{completion_id: 1, void: %Pb.Void{}},
        %Pb.SignalNotificationMessage{
          signal_id: {:idx, 1},
          result: {:void, %Pb.Void{}}
        }
      ]

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] =
               run(
                 %Pb.StartMessage{id: <<1, 2, 3>>},
                 nil,
                 {AnyTimerOrAwakeable, :handle, 2},
                 replay
               )

      assert Jason.decode!(out) == [1, "ok"]
    end
  end

  describe "ctx.run with retry policy" do
    defmodule AlwaysSucceeds do
      alias Restate.Context

      def handle(ctx, _input) do
        Context.run(ctx, fn -> "ok" end)
      end
    end

    defmodule AlwaysFails do
      alias Restate.Context

      def handle(ctx, _input) do
        Context.run(ctx, fn -> raise "always fails" end,
          max_attempts: 2,
          initial_interval_ms: 1,
          factor: 1.0
        )
      end
    end

    defmodule CatchesExhaustion do
      alias Restate.Context

      def handle(ctx, _input) do
        try do
          Context.run(ctx, fn -> raise "always fails" end,
            max_attempts: 1,
            initial_interval_ms: 1,
            factor: 1.0
          )
        rescue
          _ in Restate.TerminalError -> "caught"
        end
      end
    end

    test "successful run: emits RunCommand + ProposeRunCompletion(value) + Suspension" do
      assert [
               %Pb.RunCommandMessage{result_completion_id: cid},
               %Pb.ProposeRunCompletionMessage{
                 result_completion_id: prop_cid,
                 result: {:value, "\"ok\""}
               },
               %Pb.SuspensionMessage{
                 waiting_completions: [susp_cid],
                 waiting_signals: [1]
               }
             ] = run(%Pb.StartMessage{}, nil, {AlwaysSucceeds, :handle, 2})

      assert cid == prop_cid
      assert susp_cid == cid
    end

    test "replay with stored value: returns the journaled value, no re-execute" do
      replay = [
        %Pb.RunCommandMessage{result_completion_id: 1},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 1,
          result: {:value, %Pb.Value{content: ~s("ok")}}
        }
      ]

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(%Pb.StartMessage{}, nil, {AlwaysSucceeds, :handle, 2}, replay)

      assert Jason.decode!(out) == "ok"
    end

    test "exhausted retry: proposes terminal failure (code 500), suspends" do
      # max_attempts: 2 → fun runs twice, both fail, SDK proposes a
      # terminal failure with code 500 carrying the original message.
      assert [
               %Pb.RunCommandMessage{result_completion_id: cid},
               %Pb.ProposeRunCompletionMessage{
                 result_completion_id: prop_cid,
                 result: {:failure, %Pb.Failure{code: 500, message: msg}}
               },
               %Pb.SuspensionMessage{waiting_completions: [susp_cid]}
             ] = run(%Pb.StartMessage{}, nil, {AlwaysFails, :handle, 2})

      assert cid == prop_cid
      assert susp_cid == cid
      assert msg =~ "exhausted retries"
      assert msg =~ "always fails"
    end

    test "replay with stored failure: ctx.run raises, handler can rescue + return" do
      replay = [
        %Pb.RunCommandMessage{result_completion_id: 1},
        %Pb.RunCompletionNotificationMessage{
          completion_id: 1,
          result:
            {:failure, %Pb.Failure{code: 500, message: "ctx.run exhausted retries: boom"}}
        }
      ]

      # Handler catches the terminal and returns a value. This is
      # the pattern Failing.sideEffectFailsAfterGivenAttempts uses to
      # report the post-retry counter back to the test client.
      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(%Pb.StartMessage{}, nil, {CatchesExhaustion, :handle, 2}, replay)

      assert Jason.decode!(out) == "caught"
    end

    test "RetryPolicy: exponential backoff capped at max_interval_ms" do
      p = Restate.RetryPolicy.from_opts(initial_interval_ms: 100, factor: 2.0, max_interval_ms: 500)

      assert Restate.RetryPolicy.delay_ms(p, 1) == 100
      assert Restate.RetryPolicy.delay_ms(p, 2) == 200
      assert Restate.RetryPolicy.delay_ms(p, 3) == 400
      # 4th attempt would be 800 — capped at 500.
      assert Restate.RetryPolicy.delay_ms(p, 4) == 500
      assert Restate.RetryPolicy.delay_ms(p, 5) == 500
    end

    test "RetryPolicy: exhausted? respects max_attempts (nil = infinite)" do
      assert Restate.RetryPolicy.exhausted?(%Restate.RetryPolicy{max_attempts: nil}, 1_000) ==
               false

      p = Restate.RetryPolicy.from_opts(max_attempts: 3)
      refute Restate.RetryPolicy.exhausted?(p, 2)
      assert Restate.RetryPolicy.exhausted?(p, 3)
      assert Restate.RetryPolicy.exhausted?(p, 4)
    end
  end

  describe "Workflow durable promises" do
    defmodule PromiseGetter do
      alias Restate.Context

      def handle(ctx, _input) do
        Context.get_promise(ctx, "p")
      end
    end

    defmodule PromiseRoundTrip do
      alias Restate.Context

      def handle(ctx, _input) do
        v = Context.get_promise(ctx, "p")

        case Context.peek_promise(ctx, "p") do
          {:ok, _} ->
            v

          _ ->
            raise Restate.TerminalError, message: "promise should be ready", code: 500
        end
      end
    end

    defmodule PromiseCompleter do
      alias Restate.Context

      def handle(ctx, %{"value" => v}) do
        Context.complete_promise(ctx, "p", v)
        :ok
      end
    end

    test "get_promise: first run emits GetPromiseCommand + Suspension" do
      assert [
               %Pb.GetPromiseCommandMessage{key: "p", result_completion_id: cid},
               %Pb.SuspensionMessage{waiting_completions: [susp_cid]}
             ] = run(%Pb.StartMessage{}, nil, {PromiseGetter, :handle, 2})

      assert cid == 1
      assert susp_cid == 1
    end

    test "get_promise: replay with Value notification returns the value" do
      replay = [
        %Pb.GetPromiseCommandMessage{key: "p", result_completion_id: 1},
        %Pb.GetPromiseCompletionNotificationMessage{
          completion_id: 1,
          result: {:value, %Pb.Value{content: Jason.encode!("Till")}}
        }
      ]

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(%Pb.StartMessage{}, nil, {PromiseGetter, :handle, 2}, replay)

      assert Jason.decode!(out) == "Till"
    end

    test "get_promise: replay with Failure notification raises terminal" do
      replay = [
        %Pb.GetPromiseCommandMessage{key: "p", result_completion_id: 1},
        %Pb.GetPromiseCompletionNotificationMessage{
          completion_id: 1,
          result: {:failure, %Pb.Failure{code: 409, message: "rejected"}}
        }
      ]

      assert [
               %Pb.OutputCommandMessage{
                 result: {:failure, %Pb.Failure{code: 409, message: "rejected"}}
               },
               %Pb.EndMessage{}
             ] = run(%Pb.StartMessage{}, nil, {PromiseGetter, :handle, 2}, replay)
    end

    test "peek_promise: Void completion surfaces as :pending — handler raises terminal" do
      replay = [
        %Pb.GetPromiseCommandMessage{key: "p", result_completion_id: 1},
        %Pb.GetPromiseCompletionNotificationMessage{
          completion_id: 1,
          result: {:value, %Pb.Value{content: Jason.encode!("Till")}}
        },
        %Pb.PeekPromiseCommandMessage{key: "p", result_completion_id: 2},
        %Pb.PeekPromiseCompletionNotificationMessage{
          completion_id: 2,
          result: {:void, %Pb.Void{}}
        }
      ]

      # PromiseRoundTrip raises a TerminalError when peek doesn't say :ok.
      assert [
               %Pb.OutputCommandMessage{
                 result: {:failure, %Pb.Failure{code: 500, message: "promise should be ready"}}
               },
               %Pb.EndMessage{}
             ] = run(%Pb.StartMessage{}, nil, {PromiseRoundTrip, :handle, 2}, replay)
    end

    test "peek_promise: Value completion returns {:ok, value}; full round-trip works" do
      replay = [
        %Pb.GetPromiseCommandMessage{key: "p", result_completion_id: 1},
        %Pb.GetPromiseCompletionNotificationMessage{
          completion_id: 1,
          result: {:value, %Pb.Value{content: Jason.encode!("Till")}}
        },
        %Pb.PeekPromiseCommandMessage{key: "p", result_completion_id: 2},
        %Pb.PeekPromiseCompletionNotificationMessage{
          completion_id: 2,
          result: {:value, %Pb.Value{content: Jason.encode!("Till")}}
        }
      ]

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(%Pb.StartMessage{}, nil, {PromiseRoundTrip, :handle, 2}, replay)

      assert Jason.decode!(out) == "Till"
    end

    test "complete_promise: emits CompletePromiseCommand + Suspension" do
      assert [
               %Pb.CompletePromiseCommandMessage{
                 key: "p",
                 result_completion_id: cid,
                 completion: {:completion_value, %Pb.Value{content: bytes}}
               },
               %Pb.SuspensionMessage{waiting_completions: [susp_cid]}
             ] = run(%Pb.StartMessage{}, %{"value" => "Till"}, {PromiseCompleter, :handle, 2})

      assert cid == 1
      assert susp_cid == 1
      assert Jason.decode!(bytes) == "Till"
    end

    test "complete_promise: replay with Void ack continues normally" do
      replay = [
        %Pb.CompletePromiseCommandMessage{
          key: "p",
          result_completion_id: 1,
          completion: {:completion_value, %Pb.Value{content: ~s("Till")}}
        },
        %Pb.CompletePromiseCompletionNotificationMessage{
          completion_id: 1,
          result: {:void, %Pb.Void{}}
        }
      ]

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] =
               run(%Pb.StartMessage{}, %{"value" => "Till"}, {PromiseCompleter, :handle, 2}, replay)

      assert Jason.decode!(out) == "ok"
    end

    test "get_promise: cancel + no completion → raises 409" do
      replay = [
        %Pb.GetPromiseCommandMessage{key: "p", result_completion_id: 1},
        %Pb.SignalNotificationMessage{
          signal_id: {:idx, 1},
          result: {:void, %Pb.Void{}}
        }
      ]

      assert [
               %Pb.OutputCommandMessage{
                 result: {:failure, %Pb.Failure{code: 409, message: "cancelled"}}
               },
               %Pb.EndMessage{}
             ] = run(%Pb.StartMessage{}, nil, {PromiseGetter, :handle, 2}, replay)
    end
  end

  describe "lazy state" do
    defmodule LazyReader do
      alias Restate.Context

      def handle(ctx, _input) do
        v = Context.get_state(ctx, "k1")
        %{got: v}
      end
    end

    defmodule LazyKeys do
      alias Restate.Context

      def handle(ctx, _input) do
        Context.state_keys(ctx)
      end
    end

    test "partial_state=true + missing key: emits GetLazyStateCommand + Suspension" do
      assert [
               %Pb.GetLazyStateCommandMessage{key: "k1", result_completion_id: cid},
               %Pb.SuspensionMessage{waiting_completions: [susp_cid]}
             ] = run(%Pb.StartMessage{partial_state: true}, nil, {LazyReader, :handle, 2})

      assert cid == 1
      assert susp_cid == cid
    end

    test "partial_state=false + missing key: returns nil without emitting" do
      # Eager state is the source of truth — no key, no value.
      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(%Pb.StartMessage{partial_state: false}, nil, {LazyReader, :handle, 2})

      assert Jason.decode!(out) == %{"got" => nil}
    end

    test "partial_state=true: replay with Value notification returns the value" do
      replay = [
        %Pb.GetLazyStateCommandMessage{key: "k1", result_completion_id: 1},
        %Pb.GetLazyStateCompletionNotificationMessage{
          completion_id: 1,
          result: {:value, %Pb.Value{content: Jason.encode!(42)}}
        }
      ]

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] =
               run(%Pb.StartMessage{partial_state: true}, nil, {LazyReader, :handle, 2}, replay)

      assert Jason.decode!(out) == %{"got" => 42}
    end

    test "partial_state=true: replay with Void notification returns nil" do
      replay = [
        %Pb.GetLazyStateCommandMessage{key: "k1", result_completion_id: 1},
        %Pb.GetLazyStateCompletionNotificationMessage{
          completion_id: 1,
          result: {:void, %Pb.Void{}}
        }
      ]

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] =
               run(%Pb.StartMessage{partial_state: true}, nil, {LazyReader, :handle, 2}, replay)

      assert Jason.decode!(out) == %{"got" => nil}
    end

    test "key in eager state_map: served from cache, no lazy fetch even with partial_state" do
      start = %Pb.StartMessage{
        partial_state: true,
        state_map: [%Pb.StartMessage.StateEntry{key: "k1", value: Jason.encode!(7)}]
      }

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(start, nil, {LazyReader, :handle, 2})

      assert Jason.decode!(out) == %{"got" => 7}
    end

    test "state_keys with partial_state: emits GetLazyStateKeysCommand + Suspension" do
      assert [
               %Pb.GetLazyStateKeysCommandMessage{result_completion_id: cid},
               %Pb.SuspensionMessage{waiting_completions: [susp_cid]}
             ] = run(%Pb.StartMessage{partial_state: true}, nil, {LazyKeys, :handle, 2})

      assert cid == 1
      assert susp_cid == cid
    end

    test "state_keys with partial_state: replay returns the runtime keys" do
      replay = [
        %Pb.GetLazyStateKeysCommandMessage{result_completion_id: 1},
        %Pb.GetLazyStateKeysCompletionNotificationMessage{
          completion_id: 1,
          state_keys: %Pb.StateKeys{keys: ["k1", "k2"]}
        }
      ]

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] =
               run(%Pb.StartMessage{partial_state: true}, nil, {LazyKeys, :handle, 2}, replay)

      assert Enum.sort(Jason.decode!(out)) == ["k1", "k2"]
    end

    test "state_keys with partial_state=false: returns eager state_map keys (current behaviour)" do
      start = %Pb.StartMessage{
        partial_state: false,
        state_map: [
          %Pb.StartMessage.StateEntry{key: "k1", value: ~s(1)},
          %Pb.StartMessage.StateEntry{key: "k2", value: ~s(2)}
        ]
      }

      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(start, nil, {LazyKeys, :handle, 2})

      assert Enum.sort(Jason.decode!(out)) == ["k1", "k2"]
    end

    defmodule LazyClearAll do
      alias Restate.Context

      def handle(ctx, _input) do
        Context.clear_all_state(ctx)
        # After clear_all, state is known-empty — no lazy fetch needed.
        v = Context.get_state(ctx, "k1")
        keys = Context.state_keys(ctx)
        %{got: v, keys: keys}
      end
    end

    test "clear_all_state flips partial_state to false: subsequent reads don't lazy-fetch" do
      start = %Pb.StartMessage{
        partial_state: true,
        state_map: [%Pb.StartMessage.StateEntry{key: "k1", value: ~s(1)}]
      }

      # No GetLazyStateCommand or GetLazyStateKeysCommand emitted —
      # clear_all is the truth, no need to ask the runtime.
      assert [
               %Pb.ClearAllStateCommandMessage{},
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] = run(start, nil, {LazyClearAll, :handle, 2})

      assert Jason.decode!(out) == %{"got" => nil, "keys" => []}
    end

    defmodule LazyGetTwice do
      alias Restate.Context

      def handle(ctx, _input) do
        v1 = Context.get_state(ctx, "k1")
        v2 = Context.get_state(ctx, "k1")
        %{first: v1, second: v2}
      end
    end

    test "lazy fetch is cached: second get_state for the same key doesn't re-emit" do
      replay = [
        %Pb.GetLazyStateCommandMessage{key: "k1", result_completion_id: 1},
        %Pb.GetLazyStateCompletionNotificationMessage{
          completion_id: 1,
          result: {:value, %Pb.Value{content: Jason.encode!("hello")}}
        }
      ]

      # Only ONE GetLazyStateCommand in the journal — the second
      # get_state hits the in-memory cache populated by the first.
      assert [
               %Pb.OutputCommandMessage{result: {:value, %Pb.Value{content: out}}},
               %Pb.EndMessage{}
             ] =
               run(%Pb.StartMessage{partial_state: true}, nil, {LazyGetTwice, :handle, 2}, replay)

      assert Jason.decode!(out) == %{"first" => "hello", "second" => "hello"}
    end
  end
end
