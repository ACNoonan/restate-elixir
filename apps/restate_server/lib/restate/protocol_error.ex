defmodule Restate.ProtocolError do
  @moduledoc """
  Raised by the SDK when an invocation cannot proceed because the runtime's
  view of the journal and the user code's view have diverged.

  ## When the SDK raises this

    * `pop_recorded!/2` in `Restate.Server.Invocation` — when the next user
      command (set_state, sleep, etc.) doesn't match the next recorded
      command in the journal. Means the user code was edited between
      invocations such that replay no longer reproduces the original
      execution.
    * Other journal-mismatch / protocol-violation paths added later.

  ## Wire-format mapping

  Routed to `ErrorMessage{code: 570}` for journal mismatches and
  `ErrorMessage{code: 571}` for protocol violations — codes defined in
  the V5 spec (`apps/restate_protocol/proto/dev/restate/service/protocol.proto`,
  comment on `ErrorMessage`):

    * `JOURNAL_MISMATCH = 570` — SDK cannot replay a journal due to
      mismatch between journal and actual code (DEFAULT)
    * `PROTOCOL_VIOLATION = 571` — SDK received an unexpected message
      or message variant given its state

  Both are non-retryable: Restate stops the invocation and surfaces the
  failure to the operator rather than retrying on bad code.
  """

  @journal_mismatch 570
  @protocol_violation 571

  defexception [:message, code: @journal_mismatch]

  @type t :: %__MODULE__{message: binary(), code: 570 | 571}

  @doc "Code constant for journal-mismatch failures."
  @spec journal_mismatch() :: 570
  def journal_mismatch, do: @journal_mismatch

  @doc "Code constant for protocol-violation failures."
  @spec protocol_violation() :: 571
  def protocol_violation, do: @protocol_violation
end
