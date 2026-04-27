defmodule Restate.Server.DrainCoordinatorTest do
  # async: false because the coordinator + ETS table are global state.
  use ExUnit.Case, async: false

  alias Restate.Server.DrainCoordinator

  setup do
    case Process.whereis(DrainCoordinator) do
      nil -> start_supervised!(DrainCoordinator)
      _pid -> DrainCoordinator.reset()
    end

    # Reset on test exit too — otherwise the global drain bit leaks
    # into the next test file and every Endpoint POST starts 503'ing.
    on_exit(fn ->
      if Process.whereis(DrainCoordinator), do: DrainCoordinator.reset()
    end)

    :ok
  end

  describe "draining? lookup" do
    test "false until drain is initiated" do
      refute DrainCoordinator.draining?()
    end

    test "true after drain starts" do
      # Drain blocks until the registered set is empty; with no
      # invocations registered, drain returns immediately.
      task = Task.async(fn -> DrainCoordinator.drain(1_000) end)
      # No way to read the bit between the flip and the return without
      # introducing a fake invocation; do that.
      pid = spawn(fn -> :timer.sleep(200) end)
      DrainCoordinator.register(pid)
      Process.sleep(20)

      # The drain task is now blocking on `pid` to terminate. The bit
      # should already be flipped.
      assert DrainCoordinator.draining?()

      assert {:ok, %{remaining: 0}} = Task.await(task, 2_000)
      refute Process.alive?(pid)
    end
  end

  describe "drain/1" do
    test "returns immediately with no in-flight invocations" do
      assert {:ok, %{remaining: 0}} = DrainCoordinator.drain(500)
    end

    test "waits for registered invocations to terminate, then returns" do
      pid =
        spawn(fn ->
          :timer.sleep(100)
        end)

      DrainCoordinator.register(pid)
      Process.sleep(20)

      {time_us, {:ok, %{remaining: 0}}} =
        :timer.tc(fn -> DrainCoordinator.drain(2_000) end)

      ms = time_us / 1_000
      # Should wait ~100ms for the registered process to finish, then return.
      assert ms >= 80, "drain returned too fast (#{ms}ms) — should wait for invocations"
      assert ms < 1_000, "drain over-waited (#{ms}ms) — should return promptly after pid exits"
    end

    test "honours grace_ms when invocations don't finish in time" do
      pid =
        spawn(fn ->
          :timer.sleep(5_000)
        end)

      DrainCoordinator.register(pid)
      Process.sleep(20)

      {time_us, {:ok, %{remaining: 1}}} =
        :timer.tc(fn -> DrainCoordinator.drain(200) end)

      ms = time_us / 1_000
      assert ms >= 150, "drain returned before grace window expired (#{ms}ms)"
      assert ms < 1_000, "drain blocked beyond grace window (#{ms}ms)"

      # Cleanup so the grace-violator doesn't leak across tests.
      Process.exit(pid, :kill)
    end
  end

  describe "register/1" do
    test "no-op when coordinator isn't running (graceful degradation)" do
      stop_supervised(DrainCoordinator)
      assert :ok = DrainCoordinator.register(self())
      refute DrainCoordinator.draining?()
    end

    test "auto-deregisters when the registered process exits" do
      pid = spawn(fn -> :timer.sleep(50) end)
      DrainCoordinator.register(pid)
      Process.sleep(100)

      # With pid gone, drain should still return cleanly.
      assert {:ok, %{remaining: 0}} = DrainCoordinator.drain(200)
    end
  end
end
