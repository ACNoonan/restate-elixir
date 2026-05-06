#!/usr/bin/env elixir
#
# Matrix baseline — Elixir SDK conformance × Restate server versions.
#
# Loops `restate-sdk-test-suite` over a set of restate-server image
# tags, captures JUnit XML totals per (version × suite), and emits
# a markdown report.
#
# Prerequisites:
#   * docker
#   * Java 21+
#   * sibling clone of restatedev/sdk-test-suite (default
#     `../sdk-test-suite`); the script `./gradlew shadowJar`s it on
#     first run.
#
# Usage:
#   elixir scripts/matrix_baseline.exs
#   VERSIONS=1.6.2,main elixir scripts/matrix_baseline.exs
#   REBUILD=1 elixir scripts/matrix_baseline.exs    # force-rebuild SDK image
#
# Env knobs:
#   VERSIONS        comma-separated tags     (default 1.6.0,1.6.1,1.6.2)
#   IMAGE_REPO      restate-server repo      (default docker.restate.dev/restatedev/restate)
#   SDK_IMAGE       Elixir conformance tag   (default restate-elixir-conformance:local)
#   SUITE_JAR       path to test-suite jar   (default ../sdk-test-suite/build/libs/...)
#   REBUILD         force docker build       (any non-empty value)
#   PULL_POLICY     ALWAYS or CACHED         (default CACHED)

defmodule MatrixBaseline do
  @default_versions ["1.6.0", "1.6.1", "1.6.2"]
  @default_image_repo "docker.restate.dev/restatedev/restate"
  @default_sdk_image "restate-elixir-conformance:local"
  @default_suite_jar "../sdk-test-suite/build/libs/restate-sdk-test-suite-all.jar"

  def run do
    cfg = config()
    ts = timestamp()
    matrix_root = Path.join("test_report", "matrix_#{ts}")
    File.mkdir_p!(matrix_root)

    print_banner(cfg, matrix_root, ts)
    ensure_sdk_image(cfg)
    suite_jar = ensure_suite_jar(cfg)

    results =
      Enum.reduce(cfg.versions, %{}, fn v, acc ->
        IO.puts("\n=== #{v} ===")
        report_dir = Path.join(matrix_root, v)
        File.mkdir_p!(report_dir)
        Map.put(acc, v, run_one(cfg, suite_jar, v, report_dir))
      end)

    write_report(matrix_root, results, cfg, ts)
    print_summary(results, matrix_root)

    if any_failures?(results), do: System.halt(1)
  end

  defp config do
    %{
      versions:
        case System.get_env("VERSIONS") do
          nil -> @default_versions
          s -> s |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
        end,
      image_repo: System.get_env("IMAGE_REPO", @default_image_repo),
      sdk_image: System.get_env("SDK_IMAGE", @default_sdk_image),
      suite_jar: System.get_env("SUITE_JAR", @default_suite_jar),
      rebuild: System.get_env("REBUILD") not in [nil, ""],
      pull_policy: System.get_env("PULL_POLICY", "CACHED"),
      exclusions: System.get_env("EXCLUSIONS")
    }
  end

  defp print_banner(cfg, matrix_root, ts) do
    IO.puts("=== matrix baseline #{ts} ===")
    IO.puts("  versions    : #{Enum.join(cfg.versions, ", ")}")
    IO.puts("  server repo : #{cfg.image_repo}")
    IO.puts("  sdk image   : #{cfg.sdk_image}")
    IO.puts("  pull policy : #{cfg.pull_policy}")
    IO.puts("  output      : #{matrix_root}")
  end

  defp run_one(cfg, suite_jar, version, report_dir) do
    started = System.monotonic_time(:millisecond)
    server_image = "#{cfg.image_repo}:#{version}"

    args =
      [
        "-jar",
        suite_jar,
        "run",
        "--restate-container-image=#{server_image}",
        "--report-dir=#{Path.expand(report_dir)}",
        "--image-pull-policy=#{cfg.pull_policy}"
      ] ++
        if(cfg.exclusions, do: ["--exclusions-file=#{Path.expand(cfg.exclusions)}"], else: []) ++
        [cfg.sdk_image]

    {output, exit_code} = System.cmd("java", args, stderr_to_stdout: true)
    File.write!(Path.join(report_dir, "stdout.log"), output)
    elapsed_s = (System.monotonic_time(:millisecond) - started) / 1000

    suites = parse_suite_dirs(report_dir)

    IO.puts(
      "  exit=#{exit_code}  suites=#{map_size(suites)}  elapsed=#{Float.round(elapsed_s, 1)}s"
    )

    print_per_suite(suites)

    %{exit_code: exit_code, suites: suites, elapsed_s: elapsed_s}
  end

  defp parse_suite_dirs(report_dir) do
    case File.ls(report_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&File.dir?(Path.join(report_dir, &1)))
        |> Enum.into(%{}, fn name ->
          junit = Path.join([report_dir, name, "TEST-junit-jupiter.xml"])

          totals =
            if File.exists?(junit) do
              parse_junit(junit)
            else
              %{tests: 0, failures: 0, errors: 0, skipped: 0, missing: true}
            end

          {name, totals}
        end)

      _ ->
        %{}
    end
  end

  defp parse_junit(path) do
    content = File.read!(path)

    if Regex.match?(~r/<testsuite\b/, content) do
      %{
        tests: junit_attr(content, "tests"),
        failures: junit_attr(content, "failures"),
        errors: junit_attr(content, "errors"),
        skipped: junit_attr(content, "skipped")
      }
    else
      %{tests: 0, failures: 0, errors: 0, skipped: 0, malformed: true}
    end
  end

  defp junit_attr(content, name) do
    case Regex.run(~r/<testsuite\b[^>]*?\b#{name}="(\d+)"/, content) do
      [_, n] -> String.to_integer(n)
      _ -> 0
    end
  end

  defp print_per_suite(suites) do
    suites
    |> Enum.sort()
    |> Enum.each(fn {name, t} ->
      IO.puts("    #{name} → #{format_cell(t)}")
    end)
  end

  defp ensure_sdk_image(cfg) do
    if cfg.rebuild or not image_exists?(cfg.sdk_image) do
      IO.puts("Building #{cfg.sdk_image} (this takes a few minutes)...")
      {output, exit_code} = System.cmd("docker", ["build", "-t", cfg.sdk_image, "."], stderr_to_stdout: true)

      if exit_code != 0 do
        IO.puts(output)
        Mix.raise("docker build failed")
      end

      IO.puts("  built ok")
    else
      IO.puts("Reusing existing #{cfg.sdk_image} (set REBUILD=1 to force rebuild)")
    end
  end

  defp ensure_suite_jar(cfg) do
    if File.exists?(cfg.suite_jar) do
      IO.puts("Reusing #{cfg.suite_jar}")
      cfg.suite_jar
    else
      suite_dir = Path.expand(Path.dirname(Path.dirname(Path.dirname(cfg.suite_jar))))
      gradlew = Path.join(suite_dir, "gradlew")
      IO.puts("Building sdk-test-suite jar in #{suite_dir} ...")

      {output, exit_code} =
        System.cmd(gradlew, ["shadowJar"], cd: suite_dir, stderr_to_stdout: true)

      if exit_code != 0 do
        IO.puts(output)
        Mix.raise("gradlew shadowJar failed in #{suite_dir}")
      end

      cond do
        File.exists?(cfg.suite_jar) ->
          cfg.suite_jar

        true ->
          # gradle's shadowJar may name the output differently across versions.
          # Find any *-all.jar under build/libs and use that.
          libs = Path.join([suite_dir, "build", "libs"])

          libs
          |> File.ls!()
          |> Enum.find(&String.ends_with?(&1, "-all.jar"))
          |> case do
            nil -> Mix.raise("no shadow jar found under #{libs}")
            name -> Path.join(libs, name)
          end
      end
    end
  end

  defp image_exists?(image) do
    {_, code} = System.cmd("docker", ["image", "inspect", image], stderr_to_stdout: true)
    code == 0
  end

  defp timestamp do
    {{y, mo, d}, {h, mi, s}} = :calendar.local_time()

    :io_lib.format("~4..0w~2..0w~2..0w_~2..0w~2..0w~2..0w", [y, mo, d, h, mi, s])
    |> IO.iodata_to_binary()
  end

  defp write_report(matrix_root, results, cfg, ts) do
    versions = Enum.sort(cfg.versions)

    suites =
      results
      |> Map.values()
      |> Enum.flat_map(&Map.keys(&1.suites))
      |> Enum.uniq()
      |> Enum.sort()

    header = "| suite | " <> Enum.join(versions, " | ") <> " |"
    sep = "|---|" <> String.duplicate("---|", length(versions))

    rows =
      Enum.map(suites, fn s ->
        cells =
          Enum.map(versions, fn v ->
            case get_in(results, [v, :suites, s]) do
              nil -> "—"
              t -> format_cell(t)
            end
          end)

        "| #{s} | #{Enum.join(cells, " | ")} |"
      end)

    overall =
      Enum.map(versions, fn v ->
        case results[v] do
          nil ->
            "— #{v}: not run"

          %{exit_code: code, elapsed_s: secs, suites: ss} ->
            tot = sum_field(ss, :tests)
            pass = passes(ss)
            sym = if code == 0 and tot > 0, do: "✅", else: "❌"
            "- #{sym} **#{v}** — #{pass}/#{tot}, exit=#{code}, #{Float.round(secs, 1)}s"
        end
      end)

    body = """
    # Matrix baseline — #{ts}

    Elixir SDK (`#{cfg.sdk_image}`) conformance × `#{cfg.image_repo}` versions.
    Generated by `scripts/matrix_baseline.exs`.

    ## Per-version totals

    #{Enum.join(overall, "\n")}

    ## Per-suite breakdown

    Cell format: `passed/total` plus `(f:N e:N s:N)` when not all-green.

    #{header}
    #{sep}
    #{Enum.join(rows, "\n")}

    ## Raw output

    Per-version JUnit XML and stdout under `#{matrix_root}/<version>/`.
    """

    path = Path.join(matrix_root, "REPORT.md")
    File.write!(path, body)
    IO.puts("\nReport: #{path}")
  end

  defp print_summary(results, matrix_root) do
    IO.puts("\n=== summary ===")

    Enum.each(results, fn {v, r} ->
      tot = sum_field(r.suites, :tests)
      pass = passes(r.suites)
      sym = if r.exit_code == 0 and tot > 0, do: "✅", else: "❌"
      IO.puts("  #{sym} #{v}: #{pass}/#{tot} (exit=#{r.exit_code})")
    end)

    IO.puts("  → #{matrix_root}/REPORT.md")
  end

  defp format_cell(%{missing: true}), do: "missing"
  defp format_cell(%{malformed: true}), do: "malformed"

  defp format_cell(%{tests: 0}), do: "0/0"

  defp format_cell(%{tests: t, failures: 0, errors: 0, skipped: 0}),
    do: "#{t}/#{t}"

  defp format_cell(%{tests: t, failures: f, errors: e, skipped: s}) do
    pass = t - f - e - s
    "#{pass}/#{t} (f:#{f} e:#{e} s:#{s})"
  end

  defp sum_field(suites, field) do
    suites |> Map.values() |> Enum.reduce(0, fn s, acc -> acc + Map.get(s, field, 0) end)
  end

  defp passes(suites) do
    suites
    |> Map.values()
    |> Enum.reduce(0, fn s, acc ->
      acc +
        Map.get(s, :tests, 0) - Map.get(s, :failures, 0) - Map.get(s, :errors, 0) -
        Map.get(s, :skipped, 0)
    end)
  end

  defp any_failures?(results) do
    Enum.any?(results, fn {_, r} -> r.exit_code != 0 end)
  end
end

MatrixBaseline.run()
