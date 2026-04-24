defmodule Restate.Server.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:restate_server, :port, 9080)

    children = [
      {Bandit, plug: Restate.Server.Endpoint, port: port}
    ]

    opts = [strategy: :one_for_one, name: Restate.Server.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
