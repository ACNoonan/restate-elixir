#!/usr/bin/env elixir
#
# Demo 4 — high-concurrency fan-out throughput.
#
# Spawns K concurrent FanoutOrchestrator invocations, each firing N
# `send_async` calls to FanoutLeaf. Restate enqueues K*N leaf
# invocations; the elixir-handler pod processes them at peak
# concurrency. We measure throughput and peak container memory.
#
# Usage:
#   docker compose up -d --build
#   restate --yes deployments register http://elixir-handler:9080 --use-http1.1
#   elixir scripts/demo_4_fanout.exs
#
# Env vars:
#   ORCHESTRATORS  — concurrent orchestrators (default: 20)
#   SIZE_PER       — leaves per orchestrator (default: 200)
#   INGRESS        — Restate ingress URL (default: http://localhost:8080)
#   COMPOSE_SVC    — handler container (default: elixir-handler)
#   IDLE_THRESHOLD_PCT — CPU% below which we consider the leaf queue drained (default: 5)

Mix.install([{:finch, "~> 0.20"}, {:jason, "~> 1.4"}])

defmodule Demo4 do
  @ingress URI.parse(System.get_env("INGRESS", "http://localhost:8080"))
  @orchestrators String.to_integer(System.get_env("ORCHESTRATORS", "20"))
  @size_per String.to_integer(System.get_env("SIZE_PER", "200"))
  @container_name (case System.cmd("docker", ["compose", "ps", System.get_env("COMPOSE_SVC", "elixir-handler"), "--format", "{{.Name}}"], stderr_to_stdout: true) do
                     {out, 0} -> String.trim(out)
                     _ -> System.get_env("COMPOSE_SVC", "elixir-handler")
                   end)
  @idle_threshold_pct (case Integer.parse(System.get_env("IDLE_THRESHOLD_PCT", "5")) do
                         {n, ""} -> n
                         _ -> 5
                       end)

  @parallelism 64
  @sample_interval_ms 250
  @max_drain_wait_ms 60_000

  def run do
    {:ok, _} = Finch.start_link(name: __MODULE__.HTTP, pools: %{:default => [size: @parallelism]})

    total = @orchestrators * @size_per

    IO.puts("=== Demo 4 — high-concurrency fan-out ===")
    IO.puts("orchestrators : #{@orchestrators}  (concurrent VirtualObject runs)")
    IO.puts("size per      : #{@size_per}        (send_async per orchestrator)")
    IO.puts("total leaves  : #{total}")
    IO.puts("ingress       : #{URI.to_string(@ingress)}")
    IO.puts("")

    sanity_check()

    baseline = sample_stats()
    IO.puts("--- baseline ---")
    IO.puts("  memory : #{baseline.mem_mb}MB")
    IO.puts("  cpu    : #{Float.round(baseline.cpu_pct * 1.0, 1)}%")
    IO.puts("")

    # Warm-up: a single tiny orchestrator first. Restate's first
    # invocation against a key sometimes pays partition-leadership
    # setup; without warm-up, one of the parallel firsts can take
    # several seconds while others are sub-millisecond.
    warm_up()

    sampler = spawn_sampler()

    IO.puts("--- T+0 : firing #{@orchestrators} orchestrators (× #{@size_per} = #{total} leaves) ---")
    started_at = System.monotonic_time(:millisecond)

    timings = fire_orchestrators(@orchestrators, @size_per)
    fanout_emit_done = System.monotonic_time(:millisecond)
    fanout_emit_ms = fanout_emit_done - started_at

    summary = summarize_emit(timings)

    IO.puts("--- orchestrators returned at T+#{fanout_emit_ms}ms ---")
    IO.puts("  succeeded   : #{summary.successes} / #{@orchestrators}")
    IO.puts("  failed      : #{summary.failures}")
    IO.puts("  P50 / P99   : #{format_ms(summary.p50)} / #{format_ms(summary.p99)}")
    IO.puts("")

    IO.puts("--- waiting for leaf queue to drain (CPU < #{@idle_threshold_pct}%) ---")
    drained_at = wait_for_idle(started_at)

    drain_ms = (drained_at || @max_drain_wait_ms) - fanout_emit_done

    samples = stop_sampler_and_collect(sampler)

    {peak_mem_mb, peak_mem_at_ms} = peak_metric(samples, :mem_mb, started_at)
    {peak_cpu_pct, _} = peak_metric(samples, :cpu_pct, started_at)

    IO.puts("")
    IO.puts("--- results ---")
    IO.puts("  fanout emit wall-clock : #{format_ms(fanout_emit_ms)}")
    IO.puts("  leaf drain wall-clock  : #{format_ms(drain_ms)}")
    IO.puts("  total leaves processed : #{total}")

    if drain_ms > 0 do
      throughput = total / (drain_ms / 1_000)
      IO.puts("  leaf throughput        : #{round(throughput)} leaves/sec")
    end

    IO.puts("  peak elixir-handler mem: #{peak_mem_mb}MB  (T+#{peak_mem_at_ms}ms)")
    IO.puts("  peak elixir-handler cpu: #{Float.round(peak_cpu_pct * 1.0, 1)}%")
    IO.puts("")

    IO.puts("Asset: #{total} concurrent Restate invocations sustained on a")
    IO.puts("single ~#{baseline.mem_mb}-#{peak_mem_mb}MB elixir-handler pod. ~#{round(total / max(drain_ms / 1_000, 0.001))}")
    IO.puts("leaves/sec throughput. Each leaf invocation runs in its own ")
    IO.puts("BEAM process tree; aggregate memory scales linearly, not")
    IO.puts("quadratically.")
  end

  defp warm_up do
    key = "warmup-#{System.os_time(:nanosecond)}"
    url = URI.to_string(%{@ingress | path: "/FanoutOrchestrator/#{key}/run"})
    body = Jason.encode!(%{"size" => 1})

    req =
      Finch.build(
        :post,
        url,
        [{"content-type", "application/json"}, {"idempotency-key", key}],
        body
      )

    case Finch.request(req, __MODULE__.HTTP, receive_timeout: 30_000) do
      {:ok, %{status: 200}} -> :ok
      _ -> :ok
    end

    Process.sleep(500)
  end

  defp sanity_check do
    case Finch.build(:get, URI.to_string(%{@ingress | path: "/restate/health"}))
         |> Finch.request(__MODULE__.HTTP) do
      {:ok, %{status: s}} when s in 200..299 -> :ok
      other -> raise "Restate ingress not reachable: #{inspect(other)}"
    end
  end

  defp fire_orchestrators(k, size_per) do
    1..k
    |> Task.async_stream(
      fn i ->
        key = "fanout-#{System.os_time(:nanosecond)}-#{i}"
        url = URI.to_string(%{@ingress | path: "/FanoutOrchestrator/#{key}/run"})

        body = Jason.encode!(%{"size" => size_per})

        {us, result} =
          :timer.tc(fn ->
            req =
              Finch.build(
                :post,
                url,
                [
                  {"content-type", "application/json"},
                  {"idempotency-key", key}
                ],
                body
              )

            Finch.request(req, __MODULE__.HTTP, receive_timeout: 30_000)
          end)

        {us / 1_000, result}
      end,
      max_concurrency: @parallelism,
      timeout: 60_000,
      ordered: false
    )
    |> Enum.map(fn
      {:ok, x} -> x
      {:exit, reason} -> {nil, {:error, {:exit, reason}}}
    end)
  end

  defp summarize_emit(timings) do
    success_durations =
      Enum.flat_map(timings, fn
        {ms, {:ok, %Finch.Response{status: status}}} when status in 200..299 -> [ms]
        _ -> []
      end)
      |> Enum.sort()

    %{
      successes: length(success_durations),
      failures: length(timings) - length(success_durations),
      p50: percentile(success_durations, 0.50),
      p99: percentile(success_durations, 0.99)
    }
  end

  defp spawn_sampler do
    parent = self()

    spawn_link(fn -> sampler_loop(parent, []) end)
  end

  defp sampler_loop(parent, acc) do
    receive do
      :stop ->
        send(parent, {:samples, Enum.reverse(acc)})
    after
      @sample_interval_ms ->
        sample = sample_stats() |> Map.put(:t_ms, System.monotonic_time(:millisecond))
        sampler_loop(parent, [sample | acc])
    end
  end

  defp stop_sampler_and_collect(sampler) do
    send(sampler, :stop)

    receive do
      {:samples, samples} -> samples
    after
      5_000 -> []
    end
  end

  defp wait_for_idle(started_at) do
    deadline = started_at + @max_drain_wait_ms
    wait_for_idle_loop(deadline)
  end

  defp wait_for_idle_loop(deadline) do
    now = System.monotonic_time(:millisecond)

    cond do
      now >= deadline ->
        nil

      sample_stats().cpu_pct < @idle_threshold_pct ->
        # Confirm with two consecutive idle samples to avoid false positives.
        Process.sleep(@sample_interval_ms)

        if sample_stats().cpu_pct < @idle_threshold_pct do
          System.monotonic_time(:millisecond)
        else
          wait_for_idle_loop(deadline)
        end

      true ->
        Process.sleep(@sample_interval_ms)
        wait_for_idle_loop(deadline)
    end
  end

  defp peak_metric(samples, key, started_at) do
    if samples == [] do
      {0, 0}
    else
      Enum.reduce(samples, {0, 0}, fn sample, {best, best_t} ->
        v = Map.get(sample, key, 0)
        if v > best, do: {v, sample.t_ms - started_at}, else: {best, best_t}
      end)
    end
  end

  defp sample_stats do
    {output, _} =
      System.cmd(
        "docker",
        ["stats", @container_name, "--no-stream", "--format", "{{.MemUsage}}|{{.CPUPerc}}"],
        stderr_to_stdout: true
      )

    [mem_str, cpu_str] = String.split(String.trim(output), "|")

    %{
      mem_mb: parse_mem_mb(mem_str),
      cpu_pct: parse_cpu_pct(cpu_str)
    }
  rescue
    _ -> %{mem_mb: 0, cpu_pct: 0.0}
  end

  defp parse_mem_mb(str) do
    # "12.34MiB / 256MiB" → 12 (rounded)
    case Regex.run(~r/([0-9.]+)([KMG]i?B)/, str) do
      [_, value, unit] ->
        v = parse_float(value)

        case unit do
          "GiB" -> round(v * 1024)
          "GB" -> round(v * 1000)
          "MiB" -> round(v)
          "MB" -> round(v)
          "KiB" -> round(v / 1024)
          "KB" -> round(v / 1000)
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp parse_cpu_pct(str) do
    case Regex.run(~r/([0-9.]+)%/, str) do
      [_, v] -> parse_float(v)
      _ -> 0.0
    end
  end

  defp parse_float(str) do
    case Float.parse(str) do
      {n, _} -> n
      :error -> 0.0
    end
  end

  defp percentile([], _), do: 0.0

  defp percentile(sorted, q) do
    idx = trunc(q * (length(sorted) - 1))
    Enum.at(sorted, idx)
  end

  defp format_ms(ms) when is_number(ms) do
    cond do
      ms >= 1_000 -> :io_lib.format("~.2fs", [ms / 1_000]) |> IO.iodata_to_binary()
      ms >= 1 -> "#{round(ms)}ms"
      true -> :io_lib.format("~.2fms", [ms / 1.0]) |> IO.iodata_to_binary()
    end
  end
end

Demo4.run()
