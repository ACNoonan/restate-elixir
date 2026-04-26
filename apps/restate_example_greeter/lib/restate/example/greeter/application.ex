defmodule Restate.Example.Greeter.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Restate.Server.Registry.register_service(%{
      name: "Greeter",
      type: :virtual_object,
      handlers: [
        %{
          name: "count",
          type: :exclusive,
          mfa: {Restate.Example.Greeter, :count, 2}
        },
        %{
          name: "long_greet",
          type: :exclusive,
          mfa: {Restate.Example.Greeter, :long_greet, 2}
        }
      ]
    })

    Supervisor.start_link([], strategy: :one_for_one, name: Restate.Example.Greeter.Supervisor)
  end
end
