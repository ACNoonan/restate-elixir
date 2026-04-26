defmodule Restate.TestServices.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Restate.TestServices.Failing.init_table()

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
          name: "failingCallWithEventualSuccess",
          type: :exclusive,
          mfa: {Restate.TestServices.Failing, :failing_call_with_eventual_success, 2}
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
        }
      ]
    })

    Supervisor.start_link([], strategy: :one_for_one, name: Restate.TestServices.Supervisor)
  end
end
