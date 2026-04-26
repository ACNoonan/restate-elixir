#!/usr/bin/env elixir
#
# Demo 2 — noisy-neighbor isolation. Drives the experiment described
# in PLAN.md and apps/restate_example_greeter/lib/restate/example/noisy_neighbor.ex.
#
# What it does:
#   1) Phase A (baseline)    — fires N concurrent `light` invocations,
#                              records latency of each, computes
#                              P50/P99/P999.
#   2) Phase B (under load)  — fires the same N concurrent `light`
#                              invocations + M concurrent `poisoned`
#                              invocations, all in parallel. Records
#                              latency of the light cohort only.
#   3) Reports the comparison: ratio of P99 under poisoning vs baseline.
#
# Usage:
#   elixir scripts/demo_2_noisy_neighbor.exs
#
# Env vars:
#   INGRESS         — Restate ingress URL (default: http://localhost:8080)
#   LIGHT_COUNT     — concurrent light invocations (default: 500)
#   POISONED_COUNT  — concurrent poisoned invocations during phase B (default: 5)
#   OUT_DIR         — directory for CSV dumps (default: /tmp)
#
# Prereq: a NoisyNeighbor service registered with the Restate runtime.
# See docs/demo-2-noisy-neighbor.md.

Mix.install([{:finch, "~> 0.20"}, {:jason, "~> 1.4"}])

defmodule Demo2 do
  @ingress URI.parse(System.get_env("INGRESS", "http://localhost:8080"))
  @light_count String.to_integer(System.get_env("LIGHT_COUNT", "1000"))
  @poisoned_count String.to_integer(System.get_env("POISONED_COUNT", "10"))
  @warmup_count String.to_integer(System.get_env("WARMUP_COUNT", "200"))
  @out_dir System.get_env("OUT_DIR", "/tmp")

  @poison_timeout_ms 30_000
  @light_timeout_ms 30_000
  @parallelism 1024

  def run do
    {:ok, _} = Finch.start_link(name: __MODULE__.HTTP, pools: %{:default => [size: @parallelism]})

    IO.puts("=== Demo 2 — noisy-neighbor isolation ===")
    IO.puts("ingress         : #{URI.to_string(@ingress)}")
    IO.puts("light cohort    : #{@light_count}")
    IO.puts("poisoned cohort : #{@poisoned_count}  (only fired in phase B)")
    IO.puts("warmup          : #{@warmup_count}  (discarded; primes connections + JIT)")
    IO.puts("")

    # Sanity: confirm Restate is up.
    case Finch.build(:get, URI.to_string(%{@ingress | path: "/restate/health"}))
         |> Finch.request(__MODULE__.HTTP) do
      {:ok, %{status: s}} when s in 200..299 -> :ok
      other -> raise "Restate ingress not reachable: #{inspect(other)}"
    end

    # Warm-up: primes the Finch connection pool and any JIT effects in
    # the Elixir handler. Discarded — measurement noise otherwise
    # (first phase always slowest).
    IO.puts("--- warming up (#{@warmup_count} light invocations, discarded) ---")
    {us, _} = :timer.tc(fn -> fire_light(@warmup_count) end)
    IO.puts("  warmup wall-clock  : #{format_ms(us / 1_000)}")
    IO.puts("")

    baseline = phase("phase A — baseline (no poisoning)", :baseline)
    poisoned = phase("phase B — under #{@poisoned_count} poisoned handlers", :poisoned)

    IO.puts("\n=== Comparison ===")
    IO.puts(format_compare("P50 ", baseline.p50, poisoned.p50))
    IO.puts(format_compare("P99 ", baseline.p99, poisoned.p99))
    IO.puts(format_compare("P999", baseline.p999, poisoned.p999))
    IO.puts(format_compare("max ", baseline.max, poisoned.max))

    IO.puts("")
    IO.puts("If isolation works: ratios stay near 1x.")
    IO.puts("If the runtime is single-event-loop and 5 long handlers")
    IO.puts("monopolize it, ratios on a comparable Node.js handler would")
    IO.puts("approach ~5,000ms / baseline_p99 ≈ 100×–1000×.")
  end

  defp phase(label, mode) do
    IO.puts("--- #{label} ---")

    poisoned_task =
      if mode == :poisoned do
        Task.async(fn -> fire_poisoned() end)
      end

    {us, timings} =
      :timer.tc(fn -> fire_light(@light_count) end)

    if poisoned_task do
      Task.await(poisoned_task, @poison_timeout_ms + 5_000)
    end

    metrics = summarize(timings)
    csv_path = Path.join(@out_dir, "demo_2_#{mode}.csv")
    write_csv(csv_path, timings)

    IO.puts("  wall-clock         : #{format_ms(us / 1_000)}")
    IO.puts("  light invocations  : #{length(timings)} (success: #{metrics.successes}, failures: #{metrics.failures})")
    IO.puts("  P50  / P99  / P999 : #{format_ms(metrics.p50)} / #{format_ms(metrics.p99)} / #{format_ms(metrics.p999)}")
    IO.puts("  min  / max         : #{format_ms(metrics.min)} / #{format_ms(metrics.max)}")
    IO.puts("  csv                : #{csv_path}")
    IO.puts("")

    metrics
  end

  defp fire_light(n) do
    1..n
    |> Task.async_stream(
      fn _ ->
        key = random_key()
        url = invoke_url("NoisyNeighbor", key, "light")
        {us, result} = :timer.tc(fn -> post(url, "null") end)
        {us / 1_000, result}
      end,
      max_concurrency: @parallelism,
      timeout: @light_timeout_ms,
      ordered: false
    )
    |> Enum.map(fn
      {:ok, x} -> x
      {:exit, reason} -> {nil, {:error, {:exit, reason}}}
    end)
  end

  defp fire_poisoned do
    # Fired in parallel with the light cohort. We don't measure
    # poisoned latency here (each takes ~5s); we just need them
    # actively running while the light cohort issues requests.
    1..@poisoned_count
    |> Task.async_stream(
      fn _ ->
        key = random_key()
        url = invoke_url("NoisyNeighbor", key, "poisoned")
        post(url, "null")
      end,
      max_concurrency: @poisoned_count,
      timeout: @poison_timeout_ms,
      ordered: false
    )
    |> Enum.to_list()
  end

  defp invoke_url(service, key, handler) do
    URI.to_string(%{@ingress | path: "/#{service}/#{key}/#{handler}"})
  end

  defp post(url, body) do
    req =
      Finch.build(:post, url, [{"content-type", "application/json"}], body)

    case Finch.request(req, __MODULE__.HTTP, receive_timeout: @light_timeout_ms) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Finch.Response{status: status, body: b}} -> {:error, {:status, status, b}}
      other -> {:error, other}
    end
  end

  defp random_key do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp summarize(timings) do
    durations =
      Enum.flat_map(timings, fn
        {ms, :ok} -> [ms]
        _ -> []
      end)
      |> Enum.sort()

    successes = length(durations)
    failures = length(timings) - successes

    %{
      successes: successes,
      failures: failures,
      p50: percentile(durations, 0.50),
      p99: percentile(durations, 0.99),
      p999: percentile(durations, 0.999),
      min: List.first(durations) || 0.0,
      max: List.last(durations) || 0.0
    }
  end

  defp percentile([], _q), do: 0.0

  defp percentile(sorted, q) do
    n = length(sorted)
    idx = trunc(q * (n - 1))
    Enum.at(sorted, idx)
  end

  defp write_csv(path, timings) do
    rows =
      Enum.map(timings, fn
        {ms, :ok} -> "#{ms},ok"
        {ms, {:error, reason}} -> "#{ms || ""},error,#{inspect(reason)}"
      end)

    File.write!(path, "duration_ms,status,detail\n" <> Enum.join(rows, "\n"))
  end

  defp format_ms(ms) when is_number(ms) do
    cond do
      ms >= 1_000 -> :io_lib.format("~.2fs", [ms / 1_000]) |> IO.iodata_to_binary()
      ms >= 1 -> :io_lib.format("~.2fms", [ms]) |> IO.iodata_to_binary()
      true -> :io_lib.format("~.3fms", [ms]) |> IO.iodata_to_binary()
    end
  end

  defp format_compare(label, baseline, poisoned) do
    ratio =
      if baseline > 0, do: poisoned / baseline, else: 0.0

    "  #{label}  baseline=#{format_ms(baseline)}\tpoisoned=#{format_ms(poisoned)}\tratio=#{:io_lib.format("~.2fx", [ratio]) |> IO.iodata_to_binary()}"
  end
end

Demo2.run()
