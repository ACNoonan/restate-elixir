defmodule Restate.RequestIdentity.Base58 do
  @moduledoc false

  # Bitcoin Base58 alphabet (matches Java SDK's Base58.java verbatim).
  # 58 chars: 0-9 minus 0; A-Z minus I, O; a-z minus l. Skipped chars
  # are visually ambiguous.
  @alphabet ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  @indexes Map.new(Enum.with_index(@alphabet))
  @alphabet_tuple List.to_tuple(@alphabet)

  @doc """
  Decode a base58 string to bytes. Raises on invalid characters.
  Empty input returns `<<>>`.
  """
  @spec decode!(binary()) :: binary()
  def decode!(""), do: <<>>

  def decode!(input) when is_binary(input) do
    chars = :binary.bin_to_list(input)

    digits =
      Enum.map(chars, fn c ->
        case Map.fetch(@indexes, c) do
          {:ok, v} ->
            v

          :error ->
            raise ArgumentError,
                  "Restate.RequestIdentity.Base58: invalid character #{inspect(<<c>>)}"
        end
      end)

    leading_zeros = digits |> Enum.take_while(&(&1 == 0)) |> length()
    int = Enum.reduce(digits, 0, fn d, acc -> acc * 58 + d end)
    body = if int == 0, do: <<>>, else: :binary.encode_unsigned(int)

    :binary.copy(<<0>>, leading_zeros) <> body
  end

  @doc """
  Encode bytes to base58. Used by tests; the SDK only needs `decode!/1`
  in the verification path.
  """
  @spec encode!(binary()) :: binary()
  def encode!(<<>>), do: ""

  def encode!(bytes) when is_binary(bytes) do
    leading_zeros = count_leading_zeros(bytes)
    int = :binary.decode_unsigned(bytes)
    body = encode_int(int, [])

    String.duplicate("1", leading_zeros) <> body
  end

  defp count_leading_zeros(<<0, rest::binary>>), do: 1 + count_leading_zeros(rest)
  defp count_leading_zeros(_), do: 0

  defp encode_int(0, []), do: ""
  defp encode_int(0, acc), do: List.to_string(acc)

  defp encode_int(n, acc) do
    encode_int(div(n, 58), [elem(@alphabet_tuple, rem(n, 58)) | acc])
  end
end
