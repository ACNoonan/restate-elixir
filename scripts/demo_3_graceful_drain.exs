#!/usr/bin/env elixir
#
# Demo 3 — graceful drain on SIGTERM.
#
# What it does:
#   Phase 1: fires N concurrent slow_op invocations (each ~3s).
#   Phase 2: ~1s in, sends SIGTERM to the elixir-handler container
#            via `docker compose kill -s SIGTERM elixir-handler`.
#   Phase 3: waits for the N in-flight invocations to complete.
#            Reports counts: success, failed, total wall-clock.
#
# Expected outcome with the SDK's drain trap installed:
#   - All N invocations succeed.
#   - Container exits cleanly (visible in `docker compose ps`).
#   - The handler emits "SIGTERM received — draining" and
#     "Drain complete — all invocations finished gracefully" logs.
#   - Total wall-clock ≈ slow_op duration (no Restate retry storm).
#
# Without the trap (hard SIGTERM kill):
#   - Some/all in-flight invocations fail immediately when the BEAM
#     dies, then Restate retries them after the container restarts
#     (or against another pod).
#   - Wall-clock includes one or more retry cycles.
#
# Usage:
#   docker compose up -d
#   restate --yes deployments register http://elixir-handler:9080 --use-http1.1
#   elixir scripts/demo_3_graceful_drain.exs
#
# Env:
#   IN_FLIGHT      - concurrent slow_op invocations (default: 20)
#   INGRESS        - Restate ingress URL (default: http://localhost:8080)
#   SIGTERM_AFTER  - milliseconds after start before SIGTERM (default: 1000)
#   COMPOSE_SVC    - docker compose service name (default: elixir-handler)

Mix.install([{:finch, "~> 0.20"}, {:jason, "~> 1.4"}])

defmodule Demo3 do
  @ingress URI.parse(System.get_env("INGRESS", "http://localhost:8080"))
  @in_flight String.to_integer(System.get_env("IN_FLIGHT", "20"))
  @sigterm_after_ms String.to_integer(System.get_env("SIGTERM_AFTER", "1000"))
  @compose_svc System.get_env("COMPOSE_SVC", "elixir-handler")

  @parallelism 64
  @request_timeout_ms 30_000

  def run do
    {:ok, _} = Finch.start_link(name: __MODULE__.HTTP, pools: %{:default => [size: @parallelism]})

    IO.puts("=== Demo 3 — graceful drain on SIGTERM ===")
    IO.puts("ingress       : #{URI.to_string(@ingress)}")
    IO.puts("in-flight     : #{@in_flight}  (concurrent slow_op calls, ~3s each)")
    IO.puts("SIGTERM after : #{@sigterm_after_ms}ms")
    IO.puts("compose svc   : #{@compose_svc}")
    IO.puts("")

    sanity_check()

    IO.puts("--- T+0 : firing #{@in_flight} concurrent slow_op invocations ---")
    started_at = System.monotonic_time(:millisecond)

    invocations_task =
      Task.async(fn -> fire_slow_ops(@in_flight) end)

    Process.sleep(@sigterm_after_ms)
    elapsed = System.monotonic_time(:millisecond) - started_at
    IO.puts("--- T+#{elapsed}ms : sending SIGTERM ---")
    {output, _exit} = System.cmd("docker", ["compose", "kill", "-s", "SIGTERM", @compose_svc], stderr_to_stdout: true)
    IO.puts(String.trim(output))

    IO.puts("--- waiting for invocations to drain ---")

    timings = Task.await(invocations_task, @request_timeout_ms + 5_000)

    total_ms = System.monotonic_time(:millisecond) - started_at
    summary = summarize(timings)

    IO.puts("")
    IO.puts("--- results ---")
    IO.puts("  total wall-clock  : #{format_ms(total_ms)}")
    IO.puts("  success           : #{summary.successes} / #{@in_flight}")
    IO.puts("  failed            : #{summary.failures}")
    IO.puts("")
    IO.puts("  per-call duration:")
    IO.puts("    P50 / P99 / max : #{format_ms(summary.p50)} / #{format_ms(summary.p99)} / #{format_ms(summary.max)}")
    IO.puts("")

    IO.puts("--- container status ---")
    {ps_out, _} = System.cmd("docker", ["compose", "ps", @compose_svc, "--format", "{{.Status}}"])
    IO.puts("  #{String.trim(ps_out)}")
    IO.puts("")

    if summary.failures == 0 do
      IO.puts("✓ All in-flight invocations completed gracefully.")
      IO.puts("  Check `docker compose logs #{@compose_svc}` for the drain trace:")
      IO.puts("    SIGTERM received — draining (grace 25000ms)")
      IO.puts("    Drain complete — all invocations finished gracefully")
    else
      IO.puts("✗ #{summary.failures} invocation(s) failed.")
      IO.puts("  Without the SIGTERM trap, the BEAM would have hard-stopped")
      IO.puts("  while these invocations were running.")
    end
  end

  defp sanity_check do
    case Finch.build(:get, URI.to_string(%{@ingress | path: "/restate/health"}))
         |> Finch.request(__MODULE__.HTTP) do
      {:ok, %{status: s}} when s in 200..299 -> :ok
      other -> raise "Restate ingress not reachable at #{URI.to_string(@ingress)}: #{inspect(other)}"
    end
  end

  defp fire_slow_ops(n) do
    1..n
    |> Task.async_stream(
      fn _ ->
        key = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
        url = URI.to_string(%{@ingress | path: "/NoisyNeighbor/#{key}/slow_op"})
        {us, result} = :timer.tc(fn -> post(url) end)
        {us / 1_000, result}
      end,
      max_concurrency: @parallelism,
      timeout: @request_timeout_ms,
      ordered: false
    )
    |> Enum.map(fn
      {:ok, x} -> x
      {:exit, reason} -> {nil, {:error, {:exit, reason}}}
    end)
  end

  defp post(url) do
    req = Finch.build(:post, url, [{"content-type", "application/json"}], "null")

    case Finch.request(req, __MODULE__.HTTP, receive_timeout: @request_timeout_ms) do
      {:ok, %Finch.Response{status: 200}} -> :ok
      {:ok, %Finch.Response{status: status, body: b}} -> {:error, {:status, status, b}}
      other -> {:error, other}
    end
  end

  defp summarize(timings) do
    durations =
      Enum.flat_map(timings, fn
        {ms, :ok} -> [ms]
        _ -> []
      end)
      |> Enum.sort()

    %{
      successes: length(durations),
      failures: length(timings) - length(durations),
      p50: percentile(durations, 0.50),
      p99: percentile(durations, 0.99),
      max: List.last(durations) || 0.0
    }
  end

  defp percentile([], _), do: 0.0

  defp percentile(sorted, q) do
    idx = trunc(q * (length(sorted) - 1))
    Enum.at(sorted, idx)
  end

  defp format_ms(ms) when is_number(ms) do
    cond do
      ms >= 1_000 -> :io_lib.format("~.2fs", [ms / 1_000]) |> IO.iodata_to_binary()
      true -> :io_lib.format("~.0fms", [ms]) |> IO.iodata_to_binary()
    end
  end
end

Demo3.run()
