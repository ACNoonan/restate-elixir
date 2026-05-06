defmodule Restate.Example.Greeter.Application do
  @moduledoc false

  use Application

  # Service modules — each one declares its public name + handler
  # surface via `use Restate.Service` + `@handler` annotations. The
  # registration loop below collects their `__restate_service__/0`
  # maps and registers them with `Restate.Server.Registry`.
  @services [
    Restate.Example.Greeter,
    Restate.Example.Fanout.Orchestrator,
    Restate.Example.Fanout.Leaf,
    Restate.Example.NoisyNeighbor
  ]

  @impl true
  def start(_type, _args) do
    Enum.each(@services, fn mod ->
      Restate.Server.Registry.register_service(mod.__restate_service__())
    end)

    Supervisor.start_link([], strategy: :one_for_one, name: Restate.Example.Greeter.Supervisor)
  end
end
