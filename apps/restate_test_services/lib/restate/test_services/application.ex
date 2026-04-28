defmodule Restate.TestServices.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Restate.TestServices.Failing.init_table()

    Restate.Server.Registry.register_service(%{
      name: "KillTestRunner",
      type: :virtual_object,
      handlers: [
        %{
          name: "startCallTree",
          type: :exclusive,
          mfa: {Restate.TestServices.KillTest.Runner, :start_call_tree, 2}
        }
      ]
    })

    Restate.Server.Registry.register_service(%{
      name: "KillTestSingleton",
      type: :virtual_object,
      handlers: [
        %{
          name: "recursiveCall",
          type: :exclusive,
          mfa: {Restate.TestServices.KillTest.Singleton, :recursive_call, 2}
        },
        %{
          name: "isUnlocked",
          type: :exclusive,
          mfa: {Restate.TestServices.KillTest.Singleton, :is_unlocked, 2}
        }
      ]
    })

    Restate.Server.Registry.register_service(%{
      name: "CancelTestRunner",
      type: :virtual_object,
      handlers: [
        %{
          name: "startTest",
          type: :exclusive,
          mfa: {Restate.TestServices.CancelTest.Runner, :start_test, 2}
        },
        %{
          name: "verifyTest",
          type: :exclusive,
          mfa: {Restate.TestServices.CancelTest.Runner, :verify_test, 2}
        }
      ]
    })

    Restate.Server.Registry.register_service(%{
      name: "CancelTestBlockingService",
      type: :virtual_object,
      handlers: [
        %{
          name: "block",
          type: :exclusive,
          mfa: {Restate.TestServices.CancelTest.BlockingService, :block, 2}
        },
        %{
          name: "isUnlocked",
          type: :exclusive,
          mfa: {Restate.TestServices.CancelTest.BlockingService, :is_unlocked, 2}
        }
      ]
    })

    Restate.Server.Registry.register_service(%{
      name: "AwakeableHolder",
      type: :virtual_object,
      handlers: [
        %{
          name: "hold",
          type: :exclusive,
          mfa: {Restate.TestServices.AwakeableHolder, :hold, 2}
        },
        %{
          name: "hasAwakeable",
          type: :exclusive,
          mfa: {Restate.TestServices.AwakeableHolder, :has_awakeable, 2}
        },
        %{
          name: "unlock",
          type: :exclusive,
          mfa: {Restate.TestServices.AwakeableHolder, :unlock, 2}
        },
        %{
          name: "echoRoundTrip",
          type: :exclusive,
          mfa: {Restate.TestServices.AwakeableHolder, :echo_round_trip, 2}
        }
      ]
    })

    Restate.Server.Registry.register_service(%{
      name: "Counter",
      type: :virtual_object,
      handlers: [
        %{name: "add", type: :exclusive, mfa: {Restate.TestServices.Counter, :add, 2}},
        %{
          name: "addThenFail",
          type: :exclusive,
          mfa: {Restate.TestServices.Counter, :add_then_fail, 2}
        },
        %{name: "get", type: :shared, mfa: {Restate.TestServices.Counter, :get, 2}},
        %{name: "reset", type: :exclusive, mfa: {Restate.TestServices.Counter, :reset, 2}}
      ]
    })

    Restate.Server.Registry.register_service(%{
      name: "Failing",
      type: :virtual_object,
      handlers: [
        %{
          name: "terminallyFailingCall",
          type: :exclusive,
          mfa: {Restate.TestServices.Failing, :terminally_failing_call, 2}
        },
        %{
          name: "callTerminallyFailingCall",
          type: :exclusive,
          mfa: {Restate.TestServices.Failing, :call_terminally_failing_call, 2}
        },
        %{
          name: "terminallyFailingSideEffect",
          type: :exclusive,
          mfa: {Restate.TestServices.Failing, :terminally_failing_side_effect, 2}
        },
        %{
          name: "failingCallWithEventualSuccess",
          type: :exclusive,
          mfa: {Restate.TestServices.Failing, :failing_call_with_eventual_success, 2}
        },
        %{
          name: "sideEffectSucceedsAfterGivenAttempts",
          type: :exclusive,
          mfa: {Restate.TestServices.Failing, :side_effect_succeeds_after_given_attempts, 2}
        },
        %{
          name: "sideEffectFailsAfterGivenAttempts",
          type: :exclusive,
          mfa: {Restate.TestServices.Failing, :side_effect_fails_after_given_attempts, 2}
        }
      ]
    })

    Restate.Server.Registry.register_service(%{
      name: "MapObject",
      type: :virtual_object,
      handlers: [
        %{name: "set", type: :exclusive, mfa: {Restate.TestServices.MapObject, :set, 2}},
        %{name: "get", type: :shared, mfa: {Restate.TestServices.MapObject, :get, 2}},
        %{name: "clearAll", type: :exclusive, mfa: {Restate.TestServices.MapObject, :clear_all, 2}}
      ]
    })

    Restate.Server.Registry.register_service(%{
      name: "Proxy",
      type: :service,
      handlers: [
        %{name: "call", type: nil, mfa: {Restate.TestServices.Proxy, :call, 2}},
        %{name: "oneWayCall", type: nil, mfa: {Restate.TestServices.Proxy, :one_way_call, 2}},
        %{name: "manyCalls", type: nil, mfa: {Restate.TestServices.Proxy, :many_calls, 2}}
      ]
    })

    Restate.Server.Registry.register_service(%{
      name: "BlockAndWaitWorkflow",
      type: :workflow,
      handlers: [
        %{
          name: "run",
          type: :workflow,
          mfa: {Restate.TestServices.BlockAndWaitWorkflow, :run, 2}
        },
        %{
          name: "unblock",
          type: :shared,
          mfa: {Restate.TestServices.BlockAndWaitWorkflow, :unblock, 2}
        },
        %{
          name: "getState",
          type: :shared,
          mfa: {Restate.TestServices.BlockAndWaitWorkflow, :get_state, 2}
        }
      ]
    })

    Restate.Server.Registry.register_service(%{
      name: "VirtualObjectCommandInterpreter",
      type: :virtual_object,
      handlers: [
        %{
          name: "interpretCommands",
          type: :exclusive,
          mfa: {Restate.TestServices.CommandInterpreter, :interpret_commands, 2}
        },
        %{
          name: "resolveAwakeable",
          type: :shared,
          mfa: {Restate.TestServices.CommandInterpreter, :resolve_awakeable, 2}
        },
        %{
          name: "rejectAwakeable",
          type: :shared,
          mfa: {Restate.TestServices.CommandInterpreter, :reject_awakeable, 2}
        },
        %{
          name: "hasAwakeable",
          type: :shared,
          mfa: {Restate.TestServices.CommandInterpreter, :has_awakeable, 2}
        },
        %{
          name: "getResults",
          type: :shared,
          mfa: {Restate.TestServices.CommandInterpreter, :get_results, 2}
        }
      ]
    })

    Restate.Server.Registry.register_service(%{
      name: "TestUtilsService",
      type: :service,
      handlers: [
        %{name: "echo", type: nil, mfa: {Restate.TestServices.TestUtilsService, :echo, 2}},
        %{
          name: "uppercaseEcho",
          type: nil,
          mfa: {Restate.TestServices.TestUtilsService, :uppercase_echo, 2}
        },
        %{
          name: "sleepConcurrently",
          type: nil,
          mfa: {Restate.TestServices.TestUtilsService, :sleep_concurrently, 2}
        },
        %{
          name: "cancelInvocation",
          type: nil,
          mfa: {Restate.TestServices.TestUtilsService, :cancel_invocation, 2}
        },
        %{
          name: "countExecutedSideEffects",
          type: nil,
          mfa: {Restate.TestServices.TestUtilsService, :count_executed_side_effects, 2}
        }
      ]
    })

    Supervisor.start_link([], strategy: :one_for_one, name: Restate.TestServices.Supervisor)
  end
end
