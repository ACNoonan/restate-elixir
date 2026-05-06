defmodule Restate.Credo.Checks.NonDeterminism do
  @moduledoc """
  Credo check that flags non-deterministic function calls in handler
  modules outside of a `Restate.Context.run/2` (or `/3`) lambda.

  Restate's durability model relies on handler code being **replay
  deterministic**: every time the runtime resumes an invocation, the
  handler re-executes from the top with the same input, and the
  sequence of journaled operations must match what was recorded the
  first time. Calls that read wall-clock time, the system PRNG, fresh
  refs, the OS, or other non-deterministic sources will produce
  different values on replay — silently corrupting handler logic
  that depends on them, or surfacing as a `JOURNAL_MISMATCH` (code
  570) when they affect a journaled op.

  The blessed escape hatch is `Restate.Context.run/2` (or `/3`):

      Restate.Context.run(ctx, fn -> DateTime.utc_now() end)

  Inside that lambda, the SDK journals the *result* of the function
  the first time it runs and replays the recorded value on resume,
  so the side-effecting call is effectively safe.

  This check is opt-in. Enable it in your project's `.credo.exs`:

      %{
        configs: [
          %{
            name: "default",
            checks: %{
              extra: [
                {Restate.Credo.Checks.NonDeterminism, []}
              ]
            }
          }
        ]
      }

  ## What's flagged

  By default, calls to these functions are flagged unless they appear
  inside a `Restate.Context.run/2,3` lambda:

    * `:rand.*` — `:rand.uniform/0,1`, `:rand.normal/0,2`,
      `:rand.bytes/1,2`, `:rand.uniform_real/0`, etc.
    * `:crypto.strong_rand_bytes/1`
    * Time: `DateTime.utc_now/0,1`, `DateTime.now/1,2`,
      `DateTime.now!/1,2`, `Date.utc_today/0,1`,
      `NaiveDateTime.utc_now/0,1`, `Time.utc_now/0,1`,
      `:os.system_time/0,1`, `:os.timestamp/0`,
      `:erlang.system_time/0,1`, `:erlang.monotonic_time/0,1`,
      `:erlang.timestamp/0`, `:erlang.now/0`,
      `System.system_time/0,1`, `System.monotonic_time/0,1`,
      `System.os_time/0,1`
    * Identity-as-state: `:erlang.unique_integer/0,1`,
      `System.unique_integer/0,1`, `make_ref/0`, `Node.self/0`

  ## Scoping

  This check only walks files that reference `Restate.Context`
  somewhere in their source. Files that don't touch the SDK are
  skipped entirely, so adding the check to a generic Elixir project
  won't drown unrelated modules in warnings.

  ## Limitations

    * If a handler calls a helper function elsewhere in the codebase
      that contains a forbidden call, the helper will be warned on
      independently — even if the helper is meant to be called
      *only* from inside `ctx.run`. Either move the helper inside
      the `ctx.run` lambda, or add the helper's module to the
      `excluded_modules` parameter.
    * `Restate.Context.run/2,3` arguments other than the lambda
      (e.g. the keyword list of retry options on `run/3`) are
      scanned as normal — only the `fn -> ... end` (or `& ... /0`)
      argument has its body skipped.
    * Variable arguments (`Restate.Context.run(ctx, fun_var)`) are
      treated as opaque; the check trusts that whatever produces
      `fun_var` is itself a 0-arity function whose body is
      deterministically journaled.

  ## Parameters

  - `excluded_modules` (list of module aliases): modules whose
    function bodies should not be scanned. Useful for helper
    modules whose `DateTime.utc_now/0` calls are intentionally
    non-deterministic and consumed only by tests.

      {Restate.Credo.Checks.NonDeterminism,
       excluded_modules: [MyApp.NotAHandler, MyApp.TestHelpers]}
  """

  use Credo.Check,
    id: "EX9001",
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Handler code outside of `Restate.Context.run/2,3` must be
      replay-deterministic. Calls like `DateTime.utc_now/0` or
      `:rand.uniform/0` produce different values on each replay,
      breaking durability guarantees. Wrap them in
      `Restate.Context.run(ctx, fn -> ... end)` so the SDK journals
      the result and replays it deterministically.
      """,
      params: [
        excluded_modules: "Modules whose function bodies should not be scanned (list of module aliases)."
      ]
    ],
    param_defaults: [excluded_modules: []]

  alias Credo.Check.Context
  alias Credo.SourceFile

  # Sentinel atom returned in place of a Restate.Context.run AST node so
  # Macro.prewalk doesn't auto-descend into the lambda body. Any atom
  # works — Macro.prewalk only descends into nodes that have children.
  @run_handled :__restate_run_handled__

  @forbidden_remote MapSet.new([
                      # :rand
                      {:rand, :uniform, 0},
                      {:rand, :uniform, 1},
                      {:rand, :uniform_real, 0},
                      {:rand, :uniform_real_s, 1},
                      {:rand, :normal, 0},
                      {:rand, :normal, 2},
                      {:rand, :bytes, 1},
                      {:rand, :bytes_s, 2},
                      # :crypto
                      {:crypto, :strong_rand_bytes, 1},
                      # :os
                      {:os, :system_time, 0},
                      {:os, :system_time, 1},
                      {:os, :timestamp, 0},
                      # :erlang
                      {:erlang, :system_time, 0},
                      {:erlang, :system_time, 1},
                      {:erlang, :monotonic_time, 0},
                      {:erlang, :monotonic_time, 1},
                      {:erlang, :timestamp, 0},
                      {:erlang, :now, 0},
                      {:erlang, :unique_integer, 0},
                      {:erlang, :unique_integer, 1},
                      # Elixir DateTime / Date / Time
                      {DateTime, :utc_now, 0},
                      {DateTime, :utc_now, 1},
                      {DateTime, :now, 1},
                      {DateTime, :now, 2},
                      {DateTime, :now!, 1},
                      {DateTime, :now!, 2},
                      {Date, :utc_today, 0},
                      {Date, :utc_today, 1},
                      {NaiveDateTime, :utc_now, 0},
                      {NaiveDateTime, :utc_now, 1},
                      {Time, :utc_now, 0},
                      {Time, :utc_now, 1},
                      # Elixir System
                      {System, :system_time, 0},
                      {System, :system_time, 1},
                      {System, :monotonic_time, 0},
                      {System, :monotonic_time, 1},
                      {System, :os_time, 0},
                      {System, :os_time, 1},
                      {System, :unique_integer, 0},
                      {System, :unique_integer, 1},
                      # Elixir Node
                      {Node, :self, 0}
                    ])

  # Forbidden local calls (no module prefix). Currently just `make_ref/0`.
  @forbidden_local MapSet.new([{:make_ref, 0}])

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)

    if scope_in?(source_file) do
      excluded = excluded_module_set(params)
      ctx = Map.put(ctx, :excluded, excluded)
      Credo.Code.prewalk(source_file, &walk/2, ctx).issues
    else
      []
    end
  end

  # File-level scope: only walk files that reference Restate.Context
  # somewhere. The textual check is intentionally permissive — an
  # `alias Restate.Context` line is enough to flip the file in.
  defp scope_in?(%SourceFile{} = source_file) do
    String.contains?(SourceFile.source(source_file), "Restate.Context")
  end

  defp excluded_module_set(params) do
    params
    |> Keyword.get(:excluded_modules, [])
    |> List.wrap()
    |> Enum.map(&normalize_module/1)
    |> MapSet.new()
  end

  defp normalize_module(mod) when is_atom(mod), do: mod

  defp normalize_module(mod) when is_binary(mod) do
    Module.concat([mod])
  end

  # Restate.Context.run(ctx, fun) and Restate.Context.run(ctx, fun, opts):
  # walk the args ourselves so we can skip the lambda body, then return
  # the sentinel so Macro.prewalk doesn't double-walk.
  defp walk(
         {{:., _, [{:__aliases__, _, [:Restate, :Context]}, :run]}, _meta, args} = _ast,
         ctx
       )
       when is_list(args) do
    ctx =
      args
      |> Enum.with_index()
      |> Enum.reduce(ctx, fn {arg, idx}, acc ->
        cond do
          # The 2nd positional arg (index 1) is the user lambda. Skip
          # the lambda body entirely — its non-determinism is the
          # whole reason ctx.run exists.
          idx == 1 and lambda_or_capture?(arg) ->
            acc

          true ->
            Credo.Code.prewalk(arg, &walk/2, acc)
        end
      end)

    {@run_handled, ctx}
  end

  # Module body — track the current module so excluded_modules works.
  defp walk({:defmodule, _meta, [{:__aliases__, _, parts}, [do: _body]]} = ast, ctx) do
    mod = Module.concat(parts)

    if MapSet.member?(ctx.excluded, mod) do
      # Skip the entire module body — return the sentinel so
      # Macro.prewalk doesn't descend.
      {@run_handled, ctx}
    else
      {ast, ctx}
    end
  end

  # Remote call: Module.fun(args) or :erlang_module.fun(args).
  defp walk({{:., _, [module_ast, fun]}, meta, args} = ast, ctx)
       when is_atom(fun) and is_list(args) do
    case resolve_module(module_ast) do
      {:ok, mod} ->
        mfa = {mod, fun, length(args)}

        if MapSet.member?(@forbidden_remote, mfa) do
          # Trigger is the function name so Credo can highlight the
          # call site (`DateTime.utc_now()` highlights `utc_now`); the
          # full Module.fun/arity form goes in the message.
          trigger = Atom.to_string(fun)
          formatted = format_mfa(mod, fun, length(args))
          {ast, Context.put_issue(ctx, issue_for(ctx, meta, trigger, formatted))}
        else
          {ast, ctx}
        end

      :error ->
        {ast, ctx}
    end
  end

  # Local call: fun(args), no module prefix. We only flag a small set
  # (currently just make_ref/0). Don't flag anything that resembles a
  # def/defp/private DSL — those are syntactic forms, not function
  # calls.
  defp walk({fun, meta, args} = ast, ctx)
       when is_atom(fun) and is_list(args) do
    arity = length(args)

    if MapSet.member?(@forbidden_local, {fun, arity}) do
      # Trigger is just the function name so Credo can highlight it
      # in the source; the formatted MFA goes in the message.
      trigger = Atom.to_string(fun)
      formatted = "#{fun}/#{arity}"
      {ast, Context.put_issue(ctx, issue_for(ctx, meta, trigger, formatted))}
    else
      {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  # `module_ast` resolution. Aliases like `DateTime` come through as
  # `{:__aliases__, _, [:DateTime]}`; erlang modules come through as
  # bare atoms `:rand`. Reject anything else (variables holding modules,
  # macro-time computed module names) — we can't statically resolve
  # those.
  defp resolve_module({:__aliases__, _, parts}) when is_list(parts) do
    {:ok, Module.concat(parts)}
  end

  defp resolve_module(atom) when is_atom(atom), do: {:ok, atom}

  defp resolve_module(_), do: :error

  defp lambda_or_capture?({:fn, _, _}), do: true
  defp lambda_or_capture?({:&, _, _}), do: true
  defp lambda_or_capture?(_), do: false

  defp format_mfa(mod, fun, arity) when is_atom(mod) do
    mod_str =
      case Atom.to_string(mod) do
        "Elixir." <> rest -> rest
        erlang -> ":" <> erlang
      end

    "#{mod_str}.#{fun}/#{arity}"
  end

  defp issue_for(ctx, meta, trigger, formatted) do
    format_issue(
      ctx,
      message:
        "Non-deterministic call `#{formatted}` outside `Restate.Context.run/2`. " <>
          "Wrap it in a `Restate.Context.run(ctx, fn -> ... end)` block so the SDK " <>
          "journals the result and replays it deterministically.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
