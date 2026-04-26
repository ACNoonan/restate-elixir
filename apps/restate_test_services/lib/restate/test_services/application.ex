defmodule Restate.TestServices.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
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

    Supervisor.start_link([], strategy: :one_for_one, name: Restate.TestServices.Supervisor)
  end
end
