defmodule Restate.TestHarness.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Finch, name: Restate.TestHarness.Finch}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Restate.TestHarness.Supervisor)
  end
end
