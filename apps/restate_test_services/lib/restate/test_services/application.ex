defmodule Restate.TestServices.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Restate.TestServices.Failing.init_table()

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
        }
      ]
    })

    Supervisor.start_link([], strategy: :one_for_one, name: Restate.TestServices.Supervisor)
  end
end
