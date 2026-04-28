defmodule Restate.TestServices.CommandInterpreter do
  @moduledoc """
  Mirror of `dev.restate.sdktesting.contracts.VirtualObjectCommandInterpreter`
  and `restatedev/sdk-java`'s `VirtualObjectCommandInterpreterImpl.kt`.

  A scriptable VirtualObject the conformance suite drives end-to-end
  to exercise SDK primitives (`awakeable`, `timer`, `run`) wrapped in
  awaitable combinators. Each `interpretCommands` invocation runs a
  list of commands sequentially; each command's result is appended to
  a per-key `"results"` list, and the handler returns the last
  command's result.

  ## Wire shape (kotlinx.serialization with `@SerialName`)

      { "commands": [ {"type": "createAwakeable", "awakeableKey": "awk1"},
                      {"type": "awaitAny",
                       "commands": [
                         {"type": "createAwakeable", "awakeableKey": "awk1"},
                         {"type": "sleep", "timeoutMillis": 100}
                       ]} ] }

  Top-level `commands` execute in order. Inner `commands` (inside
  `awaitAny`/`awaitAnySuccessful`/`awaitOne`) are AwaitableCommands —
  they produce handles for `Restate.Awaitable.{any,all,await}`.

  ## Awaitable handles

    * `createAwakeable`     → `{:awakeable_handle, sid}` + state(`awk-<key>`)
    * `sleep`               → `{:timer_handle, cid}` mapped to "sleep" sentinel
    * `runThrowTerminalException` → `{:resolved, {:terminal_error, _}}`
      synthetic handle. Java uses `runAsync` to produce a journaled
      DurableFuture; we don't have an async `run` yet, so the inline
      execution + catch + synthetic handle is the closest equivalent.
      Behaviour is identical from the test's POV — the awaitable
      resolves to a TerminalException at `any`/`await` time.
  """

  alias Restate.{Awaitable, Context}

  @results_state "results"

  def interpret_commands(%Context{} = ctx, %{"commands" => commands}) when is_list(commands) do
    Enum.reduce(commands, "", fn cmd, _result ->
      result = run_command(ctx, cmd)
      append_result(ctx, result)
      result
    end)
  end

  def resolve_awakeable(%Context{} = ctx, %{"awakeableKey" => key, "value" => value})
      when is_binary(key) and is_binary(value) do
    case Context.get_state(ctx, awakeable_state_key(key)) do
      nil ->
        raise Restate.TerminalError, message: "awakeable is not registerd yet", code: 500

      awakeable_id when is_binary(awakeable_id) ->
        Context.complete_awakeable(ctx, awakeable_id, value)
        nil
    end
  end

  def reject_awakeable(%Context{} = ctx, %{"awakeableKey" => key, "reason" => reason})
      when is_binary(key) and is_binary(reason) do
    case Context.get_state(ctx, awakeable_state_key(key)) do
      nil ->
        raise Restate.TerminalError, message: "awakeable is not registerd yet", code: 500

      awakeable_id when is_binary(awakeable_id) ->
        Context.reject_awakeable(ctx, awakeable_id, 500, reason)
        nil
    end
  end

  def has_awakeable(%Context{} = ctx, awakeable_key) when is_binary(awakeable_key) do
    case Context.get_state(ctx, awakeable_state_key(awakeable_key)) do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  def get_results(%Context{} = ctx, _input) do
    Context.get_state(ctx, @results_state) || []
  end

  # --- Command dispatch ---

  defp run_command(ctx, %{"type" => "awaitAny", "commands" => sub_commands}) do
    handles = Enum.map(sub_commands, &to_awaitable(ctx, &1))
    {_idx, value} = await_any_tagged(ctx, handles)
    value
  end

  defp run_command(ctx, %{"type" => "awaitAnySuccessful", "commands" => sub_commands}) do
    initial = Enum.map(sub_commands, &to_awaitable(ctx, &1))
    await_any_successful(ctx, initial)
  end

  defp run_command(ctx, %{"type" => "awaitOne", "command" => sub_command}) do
    handle = to_awaitable(ctx, sub_command)
    await_one_tagged(ctx, handle)
  end

  defp run_command(ctx, %{"type" => "awaitAwakeableOrTimeout", "awakeableKey" => key, "timeoutMillis" => timeout_ms}) do
    {awakeable_id, awakeable} = Context.awakeable(ctx)
    Context.set_state(ctx, awakeable_state_key(key), awakeable_id)
    timer = Context.timer(ctx, timeout_ms)
    tagged_timer = {:tagged_handle, timer, "sleep"}

    case await_any_tagged(ctx, [awakeable, tagged_timer]) do
      {0, value} ->
        value

      {1, _} ->
        raise Restate.TerminalError, message: "await-timeout", code: 408
    end
  end

  defp run_command(ctx, %{"type" => "resolveAwakeable"} = req), do: resolve_awakeable(ctx, req)
  defp run_command(ctx, %{"type" => "rejectAwakeable"} = req), do: reject_awakeable(ctx, req)

  defp run_command(ctx, %{"type" => "getEnvVariable", "envName" => name}) when is_binary(name) do
    Context.run(ctx, fn -> System.get_env(name) || "" end)
  end

  # --- AwaitableCommand → handle conversion ---

  defp to_awaitable(ctx, %{"type" => "createAwakeable", "awakeableKey" => key}) do
    {awakeable_id, handle} = Context.awakeable(ctx)
    Context.set_state(ctx, awakeable_state_key(key), awakeable_id)
    handle
  end

  defp to_awaitable(ctx, %{"type" => "sleep", "timeoutMillis" => ms}) do
    # Java's reference does `timer(...).map { "sleep" }` — the sleep
    # awaitable resolves to the literal string "sleep" rather than
    # void. We model this as a thin wrapper handle that the
    # combinator path doesn't care about, then post-process the value
    # at await sites. Simpler: tag the timer handle with the sentinel
    # so `await/any` substitutes it.
    timer = Context.timer(ctx, ms)
    {:tagged_handle, timer, "sleep"}
  end

  defp to_awaitable(ctx, %{"type" => "runThrowTerminalException", "reason" => reason}) do
    try do
      # Synchronously execute + catch — equivalent to Java's runAsync
      # with a throwing block. The inner ctx.run still journals the
      # failure via ProposeRunCompletion so a replay returns the same
      # error deterministically.
      Context.run(ctx, fn ->
        raise Restate.TerminalError, message: reason, code: 500
      end)

      # Unreachable, but make the compiler happy.
      {:resolved, {:ok, ""}}
    rescue
      e in Restate.TerminalError ->
        {:resolved, {:terminal_error, e}}
    end
  end

  # --- Tagged-handle support ---
  #
  # `{:tagged_handle, base, tag}` wraps a real handle so the
  # interpreter can substitute the awaited value with `tag` (used to
  # make `sleep` resolve to the literal "sleep" string, matching
  # Java's `timer(...).map { "sleep" }`). We unwrap before passing
  # the set to `Awaitable.any` and re-tag on the way out.
  #
  # `await_any_successful` bypasses `Awaitable.any/2` and goes
  # straight to the underlying GenServer call so we can read the
  # winning handle's index even on the terminal-error path —
  # `Awaitable.any` raises on failure and loses the index, which
  # the "drop the failed one and retry" loop needs to make progress.

  defp await_any_successful(ctx, handles) do
    base_handles = Enum.map(handles, &untag/1)

    case GenServer.call(ctx.pid, {:await_handles, :any, base_handles}, :infinity) do
      {:ok, {:any, idx, value}} ->
        case Enum.at(handles, idx) do
          {:tagged_handle, _, tag} -> tag
          _ -> value
        end

      {:any_terminal_error, idx, _exc} ->
        remaining = List.delete_at(handles, idx)

        case remaining do
          [] ->
            raise Restate.TerminalError,
              message: "awaitAnySuccessful: all handles failed",
              code: 500

          _ ->
            await_any_successful(ctx, remaining)
        end

      {:terminal_error, %Restate.TerminalError{} = exc} ->
        # Cancellation / fatal — propagate.
        raise exc
    end
  end

  defp untag({:tagged_handle, base, _tag}), do: base
  defp untag(handle), do: handle

  # `Awaitable.any` wrapper that understands tagged handles. Strips
  # the tag for the underlying call, then re-substitutes the tag
  # value if the winning index maps to a tagged input.
  defp await_any_tagged(ctx, handles) do
    base_handles = Enum.map(handles, &untag/1)
    {idx, raw_value} = Awaitable.any(ctx, base_handles)

    value =
      case Enum.at(handles, idx) do
        {:tagged_handle, _, tag} -> tag
        _ -> raw_value
      end

    {idx, value}
  end

  defp await_one_tagged(ctx, {:tagged_handle, base, tag}) do
    _ = Awaitable.await(ctx, base)
    tag
  end

  defp await_one_tagged(ctx, handle), do: Awaitable.await(ctx, handle)

  # --- Helpers ---

  defp awakeable_state_key(awakeable_key), do: "awk-" <> awakeable_key

  defp append_result(ctx, result) when is_binary(result) do
    current = Context.get_state(ctx, @results_state) || []
    Context.set_state(ctx, @results_state, current ++ [result])
  end

  defp append_result(ctx, result) do
    append_result(ctx, to_string_result(result))
  end

  defp to_string_result(nil), do: ""
  defp to_string_result(s) when is_binary(s), do: s
  defp to_string_result(other), do: Jason.encode!(other)
end
