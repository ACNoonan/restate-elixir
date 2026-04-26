defmodule Restate.TerminalError do
  @moduledoc """
  Raise this from a handler to fail the invocation with a *terminal*
  failure — one that's recorded in the journal as the invocation's
  result and is **not** retried by the runtime.

  Use this for business-logic failures the caller should observe (e.g.
  validation errors, "user not found"). For unexpected internal errors
  (bugs, network blips) raise an ordinary exception — the SDK emits an
  `ErrorMessage` instead, which signals "retryable".

  ## Wire-format mapping

    * `Restate.TerminalError`  → `OutputCommandMessage{ failure: Failure }` + `EndMessage`  (terminal)
    * any other exception      → `ErrorMessage{ code: 500 }`                                 (retryable)

  ## Example

      def add(ctx, value) when is_integer(value) do
        # …
      end

      def add(_ctx, _other) do
        raise Restate.TerminalError, message: "value must be an integer", code: 400
      end
  """

  defexception [:message, code: 500]

  @type t :: %__MODULE__{message: binary(), code: non_neg_integer()}
end
