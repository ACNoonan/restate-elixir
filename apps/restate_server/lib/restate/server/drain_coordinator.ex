defmodule Restate.Server.DrainCoordinator do
  @moduledoc """
  Tracks in-flight `Restate.Server.Invocation` processes and orchestrates
  graceful drain on `SIGTERM`.

  ## How it fits

      Application.start
        ├─ Restate.Server.DrainCoordinator   ← (this module)
        ├─ Bandit ... Endpoint
        └─ System.trap_signal(:sigterm, drain_then_stop/0)

      Endpoint.call(POST /invoke/...)
        ├─ DrainCoordinator.draining?()  ← read-only ETS lookup, nano-fast
        │     true  → respond 503; do not start a new Invocation
        │     false → spawn Invocation as usual
        └─ Invocation.init/1
              └─ DrainCoordinator.register(self())  ← Process.monitor

      SIGTERM
        └─ trap fires
              ├─ DrainCoordinator.drain(grace_ms)
              │     ├─ flips :draining → true (Endpoint starts 503'ing)
              │     ├─ blocks until every monitored Invocation has exited,
              │     │   or until grace_ms elapses
              │     └─ returns the count of laggards (if any)
              └─ System.stop() / :init.stop()

  ## Why ETS for the drain bit

  Endpoint reads `draining?/0` on every POST. A GenServer call would
  serialize all incoming requests through one mailbox. `:ets` named-table
  lookup with `read_concurrency: true` is constant-time and lock-free
  for readers — same idiom we already use in `Restate.Server.Registry`.

  The GenServer side only needs to (a) flip the bit when drain begins
  and (b) maintain the `Process.monitor` set of in-flight Invocations.
  """

  use GenServer

  @table __MODULE__.State

  # --- public API ------------------------------------------------------

  @doc "Start the coordinator. Mounted in `Restate.Server.Application`."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register an in-flight invocation. Called from `Restate.Server.Invocation.init/1`.
  Returns `:ok` even if the coordinator isn't running (test envs / the
  `Restate.TestServices` umbrella member that doesn't boot it).
  """
  @spec register(pid()) :: :ok
  def register(pid \\ self()) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.cast(__MODULE__, {:register, pid})
    end
  end

  @doc "Are we draining? Hot-path lookup; never blocks."
  @spec draining?() :: boolean()
  def draining? do
    case :ets.whereis(@table) do
      :undefined -> false
      _ -> :ets.lookup_element(@table, :draining, 2, false)
    end
  end

  @doc """
  Initiate drain. Flips `draining?` to true, then waits up to
  `grace_ms` for every registered invocation to terminate. Returns
  `{:ok, %{remaining: integer}}` — `remaining` is 0 on a clean drain.

  Blocks the caller for up to `grace_ms`; the trap-signal handler is
  the typical caller, so this is fine — the BEAM is shutting down
  anyway.
  """
  @spec drain(non_neg_integer()) :: {:ok, %{remaining: non_neg_integer()}}
  def drain(grace_ms \\ 25_000) do
    GenServer.call(__MODULE__, {:drain, grace_ms}, grace_ms + 5_000)
  end

  @doc "Test-only: reset state. Not part of the public surface."
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  # --- GenServer -------------------------------------------------------

  @impl true
  def init(_opts) do
    @table =
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    :ets.insert(@table, {:draining, false})
    {:ok, %{invocations: %{}}}
  end

  @impl true
  def handle_cast({:register, pid}, state) do
    if Map.has_key?(state.invocations, pid) do
      {:noreply, state}
    else
      ref = Process.monitor(pid)
      {:noreply, %{state | invocations: Map.put(state.invocations, pid, ref)}}
    end
  end

  @impl true
  def handle_call({:drain, grace_ms}, _from, state) do
    :ets.insert(@table, {:draining, true})

    deadline_ms = monotonic_ms() + grace_ms
    invocations = wait_for_invocations(state.invocations, deadline_ms)

    {:reply, {:ok, %{remaining: map_size(invocations)}},
     %{state | invocations: invocations}}
  end

  def handle_call(:reset, _from, state) do
    Enum.each(state.invocations, fn {_pid, ref} -> Process.demonitor(ref, [:flush]) end)
    :ets.insert(@table, {:draining, false})
    {:reply, :ok, %{state | invocations: %{}}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.get(state.invocations, pid) do
      ^ref -> {:noreply, %{state | invocations: Map.delete(state.invocations, pid)}}
      _ -> {:noreply, state}
    end
  end

  # --- helpers ---------------------------------------------------------

  defp wait_for_invocations(invocations, _deadline_ms) when map_size(invocations) == 0 do
    invocations
  end

  defp wait_for_invocations(invocations, deadline_ms) do
    timeout = max(0, deadline_ms - monotonic_ms())

    receive do
      {:DOWN, _ref, :process, pid, _reason} ->
        invocations
        |> Map.delete(pid)
        |> wait_for_invocations(deadline_ms)
    after
      timeout -> invocations
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
