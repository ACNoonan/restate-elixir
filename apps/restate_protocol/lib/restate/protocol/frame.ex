defmodule Restate.Protocol.Frame do
  @moduledoc """
  One decoded protocol frame: type ID, header flags, and the parsed protobuf.

  Flags carry per-message-type bits — most notably `REQUIRES_ACK` (0x8000)
  on entries the SDK wants journaled and `COMPLETED` (0x0001) on completable
  entries. Flag semantics are message-type-specific; this struct just holds
  the raw 16-bit value.
  """

  @enforce_keys [:type, :flags, :message]
  defstruct [:type, :flags, :message]

  @type t :: %__MODULE__{
          type: 0..0xFFFF,
          flags: 0..0xFFFF,
          message: struct()
        }
end
