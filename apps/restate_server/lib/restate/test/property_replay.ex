defmodule Restate.Test.PropertyReplay do
  @moduledoc """
  Test-only generic handler used by property-based replay-determinism
  tests.

  The handler interprets a list of operation tuples encoded as JSON
  arrays — each operation is a `["op_name", args...]` list — and
  performs the corresponding `Restate.Context` call. The list comes
  in as the handler's `input`, so it round-trips through the SDK's
  serde + journal exactly the way a real handler's input would.

  ## Why this exists

  `Restate.Test.CrashInjection.assert_replay_determinism/3` already
  walks every prefix of a specific handler's journal and asserts
  determinism — strong, but example-based. Pairing it with
  `StreamData`-generated op sequences turns the same harness into a
  property test: *any* op sequence the generator emits must replay
  deterministically through the SDK. The first time a generator
  finds a real bug, the property pays for itself.

  Lives under `Restate.Test.*` because it's only useful from the
  test suite — it's not part of the user-facing API. The handler
  module is `Restate.Test.PropertyReplay.GenericHandler`.

  ## Supported operations

  Each operation is a JSON array; integer values are bounded by the
  generator. Values stay in JSON-clean shapes (binary keys, integers,
  no atoms / tuples) so they survive `Jason.encode!`/`Jason.decode!`
  round-trips through the journal.

    * `["set_state", key :: binary, value :: integer]` —
      `Restate.Context.set_state/3`.
    * `["get_state", key :: binary]` — `Restate.Context.get_state/2`.
      Return value discarded; the handler's job is to drive the
      journal, not to compute a value.
    * `["clear_state", key :: binary]` —
      `Restate.Context.clear_state/2`.
    * `["sleep", ms :: integer]` — `Restate.Context.sleep/2`.
      Auto-completed by `Restate.Test.FakeRuntime`.
    * `["run", value :: integer]` — `Restate.Context.run/2` whose
      lambda returns the constant `value`. Deterministic by
      construction; lets the property test exercise the
      ProposeRunCompletion / RunCompletionNotification dance without
      pulling in real-world non-determinism.
  """

  defmodule GenericHandler do
    @moduledoc false
    alias Restate.Context

    def run(%Context{} = ctx, ops) when is_list(ops) do
      Enum.each(ops, &execute(ctx, &1))
      :ok
    end

    defp execute(ctx, ["set_state", key, value]) when is_binary(key) and is_integer(value) do
      Context.set_state(ctx, key, value)
    end

    defp execute(ctx, ["get_state", key]) when is_binary(key) do
      _ = Context.get_state(ctx, key)
      :ok
    end

    defp execute(ctx, ["clear_state", key]) when is_binary(key) do
      Context.clear_state(ctx, key)
    end

    defp execute(ctx, ["sleep", ms]) when is_integer(ms) and ms > 0 do
      Context.sleep(ctx, ms)
    end

    defp execute(ctx, ["run", value]) when is_integer(value) do
      _ = Context.run(ctx, fn -> value end)
      :ok
    end
  end
end
