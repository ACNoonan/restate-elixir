defmodule Restate.Context do
  @moduledoc """
  User-facing handle for a single invocation.

  Passed as the first argument to every handler. All `Restate.Context.*`
  functions are synchronous calls into the invocation process — they
  return the journaled value (or `nil`) and have the same crash semantics
  as a normal `GenServer.call`.

  Module lives in `restate_server` because it's tightly coupled to
  `Restate.Server.Invocation`, but its name space is `Restate.*` so user
  code reads as `alias Restate.Context`.
  """

  @enforce_keys [:pid]
  defstruct [:pid]

  @type t :: %__MODULE__{pid: pid()}

  @doc """
  Read a state value by string key.

  Returns the JSON-decoded term, or `nil` if no value is stored. Values
  are JSON-encoded on write (`set_state/3`) and JSON-decoded on read.
  """
  @spec get_state(t(), binary()) :: term() | nil
  def get_state(%__MODULE__{pid: pid}, key) when is_binary(key) do
    case GenServer.call(pid, {:get_state, key}) do
      nil -> nil
      bytes when is_binary(bytes) -> Jason.decode!(bytes)
    end
  end

  @doc """
  Write a state value. Any JSON-encodable term is accepted.
  """
  @spec set_state(t(), binary(), term()) :: :ok
  def set_state(%__MODULE__{pid: pid}, key, value) when is_binary(key) do
    GenServer.call(pid, {:set_state, key, Jason.encode!(value)})
  end
end
