defmodule Restate.Protocol.Framer do
  @moduledoc """
  8-byte header framer for the Restate V3 service protocol.

  Header layout (big-endian):

      0                   1                   2                   3
      +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
      |              Type             |             Flags             |
      +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
      |                            Length                             |
      +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

  - Type:   16-bit message type ID (see `Restate.Protocol.Messages`)
  - Flags:  16-bit per-message-type flags (REQUIRES_ACK, COMPLETED, …)
  - Length: 32-bit length of the protobuf body, header excluded
  """

  alias Restate.Protocol.{Frame, Messages}

  @type decode_result ::
          {:ok, Frame.t(), rest :: binary}
          | {:more, binary}
          | {:error, {:unknown_type, integer()}}

  @doc """
  Encode a protobuf struct into a wire frame (header + body).

  Raises if the struct's module isn't in the V3 type registry.
  """
  @spec encode(struct(), 0..0xFFFF) :: binary
  def encode(%mod{} = msg, flags \\ 0) do
    type =
      Messages.type_for_module(mod) ||
        raise ArgumentError, "no V3 type ID for #{inspect(mod)}"

    body = Protobuf.encode(msg)
    <<type::16, flags::16, byte_size(body)::32, body::binary>>
  end

  @doc """
  Decode the next frame from a binary buffer.

  Returns `{:ok, %Frame{}, rest}` when a complete frame is read,
  `{:more, buffer}` when the buffer is short, or `{:error, …}` for an
  unknown type ID.
  """
  @spec decode(binary) :: decode_result
  def decode(<<type::16, flags::16, length::32, body_and_rest::binary>> = buf) do
    case body_and_rest do
      <<body::binary-size(length), rest::binary>> ->
        case Messages.module_for_type(type) do
          nil ->
            {:error, {:unknown_type, type}}

          mod ->
            frame = %Frame{type: type, flags: flags, message: mod.decode(body)}
            {:ok, frame, rest}
        end

      _ ->
        {:more, buf}
    end
  end

  def decode(buf) when is_binary(buf), do: {:more, buf}

  @doc """
  Drain a buffer into a list of frames plus any leftover incomplete bytes.

  Returns `{:ok, frames, leftover}` or stops at the first `{:error, _}`.
  """
  @spec decode_all(binary) :: {:ok, [Frame.t()], binary} | {:error, term()}
  def decode_all(buf), do: decode_all(buf, [])

  defp decode_all(buf, acc) do
    case decode(buf) do
      {:ok, frame, rest} -> decode_all(rest, [frame | acc])
      {:more, leftover} -> {:ok, Enum.reverse(acc), leftover}
      {:error, _} = err -> err
    end
  end
end
