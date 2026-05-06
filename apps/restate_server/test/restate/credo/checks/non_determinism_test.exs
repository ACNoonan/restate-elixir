defmodule Restate.Credo.Checks.NonDeterminismTest do
  use Credo.Test.Case

  alias Restate.Credo.Checks.NonDeterminism

  describe "scoping" do
    test "skips files that don't reference Restate.Context" do
      """
      defmodule SomeApp.Helper do
        def now, do: DateTime.utc_now()
        def rand, do: :rand.uniform(100)
      end
      """
      |> to_source_file()
      |> run_check(NonDeterminism)
      |> refute_issues()
    end
  end

  describe "Restate.Context.run lambda body is exempt" do
    test "DateTime.utc_now/0 inside Restate.Context.run is fine" do
      """
      defmodule MyHandler do
        alias Restate.Context

        def handle(ctx, _input) do
          ts = Restate.Context.run(ctx, fn -> DateTime.utc_now() end)
          ts
        end
      end
      """
      |> to_source_file()
      |> run_check(NonDeterminism)
      |> refute_issues()
    end

    test "rand inside Restate.Context.run/3 with retry options is fine" do
      """
      defmodule MyHandler do
        alias Restate.Context

        def handle(ctx, _input) do
          Restate.Context.run(ctx, fn -> :rand.uniform(100) end, max_attempts: 3)
        end
      end
      """
      |> to_source_file()
      |> run_check(NonDeterminism)
      |> refute_issues()
    end

    test "captured local fn passed to Restate.Context.run is exempt" do
      """
      defmodule MyHandler do
        alias Restate.Context

        def handle(ctx, _input) do
          Restate.Context.run(ctx, &compute/0)
        end

        defp compute do
          DateTime.utc_now()
        end
      end
      """
      |> to_source_file()
      |> run_check(NonDeterminism)
      # NOTE: the helper `compute/0` is still scanned at its
      # definition site — that's the documented limitation. This
      # test documents the false-positive, not the desirable
      # behaviour. If/when the check learns intra-module taint
      # tracking, this should flip to refute_issues/1.
      |> assert_issue(fn issue -> assert issue.trigger == "utc_now" end)
    end
  end

  describe "forbidden remote calls outside Restate.Context.run" do
    test "DateTime.utc_now/0 in a handler is flagged" do
      """
      defmodule MyHandler do
        alias Restate.Context

        def handle(ctx, _input) do
          ts = DateTime.utc_now()
          Restate.Context.set_state(ctx, "ts", ts)
        end
      end
      """
      |> to_source_file()
      |> run_check(NonDeterminism)
      |> assert_issue(fn issue -> assert issue.trigger == "utc_now" end)
    end

    test ":rand.uniform/1 in a handler is flagged" do
      """
      defmodule MyHandler do
        alias Restate.Context

        def handle(ctx, _input) do
          n = :rand.uniform(100)
          Restate.Context.set_state(ctx, "n", n)
        end
      end
      """
      |> to_source_file()
      |> run_check(NonDeterminism)
      |> assert_issue(fn issue -> assert issue.trigger == "uniform" end)
    end

    test ":erlang.unique_integer/0 is flagged" do
      """
      defmodule MyHandler do
        alias Restate.Context

        def handle(ctx, _input) do
          id = :erlang.unique_integer()
          Restate.Context.set_state(ctx, "id", id)
        end
      end
      """
      |> to_source_file()
      |> run_check(NonDeterminism)
      |> assert_issue(fn issue -> assert issue.trigger == "unique_integer" end)
    end

    test "System.os_time/0 is flagged" do
      """
      defmodule MyHandler do
        alias Restate.Context

        def handle(ctx, _input) do
          t = System.os_time()
          Restate.Context.set_state(ctx, "t", t)
        end
      end
      """
      |> to_source_file()
      |> run_check(NonDeterminism)
      |> assert_issue(fn issue -> assert issue.trigger == "os_time" end)
    end

    test "multiple violations in one handler all flagged" do
      """
      defmodule MyHandler do
        alias Restate.Context

        def handle(ctx, _input) do
          ts = DateTime.utc_now()
          n = :rand.uniform(10)
          Restate.Context.set_state(ctx, "ts", ts)
          Restate.Context.set_state(ctx, "n", n)
        end
      end
      """
      |> to_source_file()
      |> run_check(NonDeterminism)
      |> assert_issues(fn issues ->
        triggers = issues |> Enum.map(& &1.trigger) |> Enum.sort()
        assert triggers == ["uniform", "utc_now"]
      end)
    end
  end

  describe "forbidden local calls" do
    test "make_ref/0 outside Restate.Context.run is flagged" do
      """
      defmodule MyHandler do
        alias Restate.Context

        def handle(ctx, _input) do
          ref = make_ref()
          Restate.Context.set_state(ctx, "ref", inspect(ref))
        end
      end
      """
      |> to_source_file()
      |> run_check(NonDeterminism)
      |> assert_issue(fn issue -> assert issue.trigger == "make_ref" end)
    end
  end

  describe "excluded_modules parameter" do
    test "skips modules listed in excluded_modules" do
      """
      defmodule MyApp.Helper do
        alias Restate.Context

        def now, do: DateTime.utc_now()
      end
      """
      |> to_source_file()
      |> run_check(NonDeterminism, excluded_modules: [MyApp.Helper])
      |> refute_issues()
    end

    test "still flags non-excluded modules" do
      """
      defmodule MyApp.Handler do
        alias Restate.Context

        def handle(ctx, _input) do
          ts = DateTime.utc_now()
          Restate.Context.set_state(ctx, "ts", ts)
        end
      end
      """
      |> to_source_file()
      |> run_check(NonDeterminism, excluded_modules: [MyApp.OtherHandler])
      |> assert_issue(fn issue -> assert issue.trigger == "utc_now" end)
    end
  end

  describe "non-violations" do
    test "Restate.Context state ops are fine" do
      """
      defmodule MyHandler do
        alias Restate.Context

        def handle(ctx, _input) do
          counter = Restate.Context.get_state(ctx, "counter") || 0
          Restate.Context.set_state(ctx, "counter", counter + 1)
        end
      end
      """
      |> to_source_file()
      |> run_check(NonDeterminism)
      |> refute_issues()
    end

    test "deterministic time arithmetic on a journaled value is fine" do
      """
      defmodule MyHandler do
        alias Restate.Context

        def handle(ctx, _input) do
          # The wake-up time was journaled in a prior ctx.run; this
          # is just deterministic math on a stored value.
          stored = Restate.Context.get_state(ctx, "wake_at")
          DateTime.add(stored, 60, :second)
        end
      end
      """
      |> to_source_file()
      |> run_check(NonDeterminism)
      |> refute_issues()
    end
  end
end
