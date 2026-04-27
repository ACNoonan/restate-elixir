defmodule Restate.Server.Application do
  @moduledoc false

  use Application

  require Logger

  @drain_grace_ms 25_000

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:restate_server, :port, 9080)

    children = [
      Restate.Server.DrainCoordinator,
      {Bandit, plug: Restate.Server.Endpoint, port: port}
    ]

    opts = [strategy: :one_for_one, name: Restate.Server.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, sup_pid} ->
        install_sigterm_trap()
        {:ok, sup_pid}

      other ->
        other
    end
  end

  # SIGTERM handler — Demo 3 (graceful drain). Flips DrainCoordinator
  # into draining mode (Endpoint starts 503'ing new POSTs), waits up
  # to @drain_grace_ms for in-flight invocations to complete, then
  # initiates orderly BEAM shutdown.
  #
  # `System.trap_signal/2` was introduced in Elixir 1.12; the handler
  # runs in the registered process. We just spawn a tiny one rather
  # than complicating the supervisor.
  defp install_sigterm_trap do
    System.trap_signal(:sigterm, :restate_drain, fn ->
      Logger.info("SIGTERM received — draining (grace #{@drain_grace_ms}ms)")

      case Restate.Server.DrainCoordinator.drain(@drain_grace_ms) do
        {:ok, %{remaining: 0}} ->
          Logger.info("Drain complete — all invocations finished gracefully")

        {:ok, %{remaining: n}} ->
          Logger.warning("Drain timed out — #{n} invocation(s) still in flight; killing")
      end

      System.stop(0)
    end)
  rescue
    UndefinedFunctionError ->
      # Older Elixir / very-locked-down runtime. Drain still works if
      # someone calls DrainCoordinator.drain manually; the SIGTERM
      # path just degrades to default BEAM shutdown.
      Logger.warning("System.trap_signal/3 unavailable — SIGTERM will hard-kill")
  end
end
