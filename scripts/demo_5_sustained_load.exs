#!/usr/bin/env elixir
#
# Demo 5 — sustained-load soak.
#
# What it does:
#   Drives a constant request rate against the elixir-handler for a
#   fixed duration, mixing two invocation shapes:
#     * Greeter.count       — eager state read + set, returns immediately
#     * Greeter.long_greet  — set state + sleep 10s + set state + return
#
#   Each second's window of completed `count` calls is bucketed and
#   reported as P50/P95/P99/max latency, alongside a `docker stats`
#   sample of the handler container's memory.
#
# What it proves:
#   On the BEAM, latency percentiles and resident memory should stay
#   FLAT across the run. There is no global heap to compact, no
#   stop-the-world GC; per-process collection runs locally and never
#   coordinates. Compared with a Java handler on the same workload —
#   canonical G1 sawtooth pause distribution — the comparison is
#   striking. (Run a Java sidecar yourself to compare; we don't ship
#   one in this repo.)
#
# Usage:
#   docker compose up -d --build
#   restate --yes deployments register http://elixir-handler:9080 --use-http1.1
#   elixir scripts/demo_5_sustained_load.exs
#
# Env (defaults are sized for a short proof-of-concept run; for
# the full 24h test set DURATION=86400 RPS=500):
#   RPS           — sustained request rate (default: 50)
#   DURATION      — total run duration in seconds (default: 60)
#   BUCKET        — reporting bucket size in seconds (default: 5)
#   MIX_LONG_PCT  — % of requests that go to long_greet (default: 20)
#   INGRESS       — Restate ingress URL (default: http://localhost:8080)
#   COMPOSE_SVC   — handler container (default: elixir-handler)

Mix.install([{:finch, "~> 0.20"}, {:jason, "~> 1.4"}])

defmodule Demo5 do
  @ingress URI.parse(System.get_env("INGRESS", "http://localhost:8080"))
  @rps String.to_integer(System.get_env("RPS", "50"))
  @duration_s String.to_integer(System.get_env("DURATION", "60"))
  @bucket_s String.to_integer(System.get_env("BUCKET", "5"))
  @mix_long_pct String.to_integer(System.get_env("MIX_LONG_PCT", "20"))
  @container_name (case System.cmd("docker", ["compose", "ps", System.get_env("COMPOSE_SVC", "elixir-handler"), "--format", "{{.Name}}"], stderr_to_stdout: true) do
                     {out, 0} -> String.trim(out)
                     _ -> System.get_env("COMPOSE_SVC", "elixir-handler")
                   end)

  @parallelism 256
  @count_timeout_ms 5_000
  @long_greet_timeout_ms 30_000

  def run do
    {:ok, _} = Finch.start_link(name: __MODULE__.HTTP, pools: %{:default => [size: @parallelism]})

    total_target = @rps * @duration_s
    long_count_target = div(total_target * @mix_long_pct, 100)
    short_count_target = total_target - long_count_target

    IO.puts("=== Demo 5 — sustained-load soak ===")
    IO.puts("rps           : #{@rps}")
    IO.puts("duration      : #{@duration_s}s")
    IO.puts("bucket        : #{@bucket_s}s")
    IO.puts("mix long_greet: #{@mix_long_pct}%")
    IO.puts("ingress       : #{URI.to_string(@ingress)}")
    IO.puts("target total  : #{total_target} (#{short_count_target} count + #{long_count_target} long_greet)")
    IO.puts("")

    sanity_check()

    baseline_mem = sample_memory_mb()
    IO.puts("baseline memory: #{baseline_mem}MB")
    IO.puts("")

    started_at = System.monotonic_time(:millisecond)

    # Drive the load from a spawned process; fire_count sends
    # `{:count_done, ...}` back to *this* process (which is also
    # running the sample_loop drain). Keeping both in the same
    # mailbox is what makes message-passing simplest.
    parent = self()

    load_pid =
      spawn_link(fn ->
        drive_load(started_at, total_target, parent)
        send(parent, :done_firing)
      end)

    samples = sample_loop(started_at, baseline_mem)

    # Wait briefly for the loader to flag done (it should have already
    # since sample_loop ran for `duration + 5s`).
    receive do
      :done_firing -> :ok
    after
      0 -> :ok
    end

    Process.exit(load_pid, :normal)

    IO.puts("\n--- per-bucket results (count latency only) ---\n")
    print_buckets(samples)

    print_summary(samples, baseline_mem)
  end

  # -------------------- Load driver --------------------

  defp drive_load(started_at, total_target, parent) do
    interval_ms = max(1, div(1_000, @rps))

    Enum.each(0..(total_target - 1), fn i ->
      target_t = started_at + i * interval_ms
      sleep_until(target_t)

      case pick_kind() do
        :count -> spawn(fn -> fire_count(parent) end)
        :long_greet -> spawn(fn -> fire_long_greet() end)
      end
    end)
  end

  defp pick_kind do
    if :rand.uniform(100) <= @mix_long_pct, do: :long_greet, else: :count
  end

  defp fire_count(parent) do
    started = System.monotonic_time(:microsecond)
    key = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    url = URI.to_string(%{@ingress | path: "/Greeter/#{key}/count"})

    req = Finch.build(:post, url, [{"content-type", "application/json"}], "null")

    result =
      case Finch.request(req, __MODULE__.HTTP, receive_timeout: @count_timeout_ms) do
        {:ok, %Finch.Response{status: 200}} -> :ok
        _ -> :error
      end

    elapsed_us = System.monotonic_time(:microsecond) - started
    send(parent, {:count_done, elapsed_us, result})
  end

  defp fire_long_greet do
    key = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    url = URI.to_string(%{@ingress | path: "/Greeter/#{key}/long_greet"})

    req = Finch.build(:post, url, [{"content-type", "application/json"}], ~s("world"))

    # Fire and forget for sustained-load purposes; we don't bucket
    # long_greet latency (it's dominated by the 10s sleep).
    Finch.request(req, __MODULE__.HTTP, receive_timeout: @long_greet_timeout_ms)
  end

  defp sleep_until(target_t) do
    now = System.monotonic_time(:millisecond)
    if target_t > now, do: Process.sleep(target_t - now)
  end

  # -------------------- Sampler --------------------

  # Collects {bucket_idx, count_us} messages from fire_count and
  # samples memory once per bucket. Runs until duration + buffer.
  defp sample_loop(started_at, baseline_mem) do
    end_at = started_at + @duration_s * 1_000

    Stream.iterate(0, &(&1 + 1))
    |> Enum.reduce_while(%{buckets: %{}, errors: 0}, fn bucket_idx, acc ->
      bucket_end = started_at + (bucket_idx + 1) * @bucket_s * 1_000

      if bucket_end > end_at + 5_000 do
        {:halt, acc}
      else
        # Drain messages until the bucket window closes.
        durations = drain_until(bucket_end, [])

        mem = sample_memory_mb()
        sorted = Enum.sort(durations)

        bucket = %{
          start_s: bucket_idx * @bucket_s,
          n: length(sorted),
          p50_ms: percentile_ms(sorted, 0.50),
          p95_ms: percentile_ms(sorted, 0.95),
          p99_ms: percentile_ms(sorted, 0.99),
          max_ms: percentile_ms(sorted, 1.0),
          mem_mb: mem,
          mem_delta: mem - baseline_mem
        }

        delta_sign = if bucket.mem_delta >= 0, do: "+", else: ""

        IO.puts(
          "  t=#{pad_left(bucket.start_s, 3)}s  " <>
            "n=#{pad_left(bucket.n, 5)}  " <>
            "p50=#{pad_left_f(bucket.p50_ms, 7)}ms  " <>
            "p95=#{pad_left_f(bucket.p95_ms, 7)}ms  " <>
            "p99=#{pad_left_f(bucket.p99_ms, 7)}ms  " <>
            "max=#{pad_left_f(bucket.max_ms, 8)}ms  " <>
            "mem=#{pad_left(bucket.mem_mb, 3)}MB (Δ#{delta_sign}#{bucket.mem_delta}MB)"
        )

        {:cont, %{acc | buckets: Map.put(acc.buckets, bucket_idx, bucket)}}
      end
    end)
  end

  defp drain_until(deadline_ms, acc) do
    timeout = max(0, deadline_ms - System.monotonic_time(:millisecond))

    receive do
      {:count_done, elapsed_us, :ok} -> drain_until(deadline_ms, [elapsed_us / 1_000.0 | acc])
      {:count_done, _, :error} -> drain_until(deadline_ms, acc)
    after
      timeout -> acc
    end
  end

  # -------------------- Reporting --------------------

  defp print_buckets(%{buckets: buckets}) do
    IO.puts("  (printed live above)")
    IO.puts("")
    IO.puts("  CSV (paste-ready):")
    IO.puts("  start_s,n,p50_ms,p95_ms,p99_ms,max_ms,mem_mb")

    buckets
    |> Map.values()
    |> Enum.sort_by(& &1.start_s)
    |> Enum.each(fn b ->
      IO.puts(
        "  #{b.start_s},#{b.n},#{Float.round(b.p50_ms, 2)},#{Float.round(b.p95_ms, 2)},#{Float.round(b.p99_ms, 2)},#{Float.round(b.max_ms, 2)},#{b.mem_mb}"
      )
    end)
  end

  defp print_summary(%{buckets: buckets}, baseline_mem) do
    # Drop empty buckets (typically the trailing one after firing
    # finishes) — they'd skew percentile-of-percentiles math.
    bs = buckets |> Map.values() |> Enum.filter(&(&1.n > 0)) |> Enum.sort_by(& &1.start_s)

    if bs == [] do
      IO.puts("\nNo bucket samples — run too short?")
    else
      total_n = bs |> Enum.map(& &1.n) |> Enum.sum()
      mems = Enum.map(bs, & &1.mem_mb)
      p50s = Enum.map(bs, & &1.p50_ms)
      p99s = Enum.map(bs, & &1.p99_ms)

      first_p99 = List.first(p99s)
      last_p99 = List.last(p99s)
      drift = last_p99 / max(first_p99, 0.1)

      IO.puts("\n--- summary ---")
      IO.puts("  count completions     : #{total_n}")
      IO.puts("  baseline memory       : #{baseline_mem}MB")
      IO.puts("  peak memory           : #{Enum.max(mems)}MB (Δ+#{Enum.max(mems) - baseline_mem}MB)")
      IO.puts("  P50 across buckets    : median #{Float.round(median(p50s), 2)}ms (min #{Float.round(Enum.min(p50s), 2)} / max #{Float.round(Enum.max(p50s), 2)})")
      IO.puts("  P99 across buckets    : median #{Float.round(median(p99s), 2)}ms (min #{Float.round(Enum.min(p99s), 2)} / max #{Float.round(Enum.max(p99s), 2)})")
      IO.puts("  P99 drift (last/first): #{Float.round(drift, 2)}× (#{Float.round(first_p99, 1)}ms → #{Float.round(last_p99, 1)}ms)")
      IO.puts("")

      cond do
        drift <= 1.5 ->
          IO.puts("✓ P99 stayed flat — no sawtooth, no degradation.")

        true ->
          IO.puts("⚠ P99 drifted >1.5× from start to end — long-run analysis recommended.")
      end
    end
  end

  defp median([]), do: 0.0

  defp median(xs) do
    sorted = Enum.sort(xs)
    n = length(sorted)
    if rem(n, 2) == 1, do: Enum.at(sorted, div(n, 2)), else: (Enum.at(sorted, div(n, 2) - 1) + Enum.at(sorted, div(n, 2))) / 2
  end

  defp percentile_ms([], _), do: 0.0

  defp percentile_ms(sorted, q) do
    idx = max(0, trunc(q * (length(sorted) - 1)))
    Enum.at(sorted, idx) || 0.0
  end

  defp pad_left(n, w), do: String.pad_leading("#{n}", w)
  defp pad_left_f(f, w), do: String.pad_leading(:io_lib.format("~.1f", [f * 1.0]) |> IO.iodata_to_binary(), w)

  # -------------------- Helpers --------------------

  defp sample_memory_mb do
    case System.cmd("docker", ["stats", "--no-stream", "--format", "{{.MemUsage}}", @container_name],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        # Output like "12.3MiB / 1.944GiB"
        out
        |> String.split("/", parts: 2)
        |> List.first()
        |> String.trim()
        |> parse_size_mb()

      _ ->
        0
    end
  end

  defp parse_size_mb(s) do
    cond do
      String.ends_with?(s, "GiB") -> trunc(parse_float(s) * 1024)
      String.ends_with?(s, "MiB") -> trunc(parse_float(s))
      String.ends_with?(s, "KiB") -> 0
      true -> 0
    end
  end

  defp parse_float(s) do
    s
    |> String.replace(~r/[^\d.]/, "")
    |> Float.parse()
    |> case do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp sanity_check do
    case Finch.build(:get, URI.to_string(%{@ingress | path: "/restate/health"}))
         |> Finch.request(__MODULE__.HTTP) do
      {:ok, %{status: s}} when s in 200..299 -> :ok
      other -> raise "Restate ingress not reachable at #{URI.to_string(@ingress)}: #{inspect(other)}"
    end
  end
end

Demo5.run()
