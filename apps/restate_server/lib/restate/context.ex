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
  defstruct [:pid, key: ""]

  @type t :: %__MODULE__{pid: pid(), key: String.t()}

  @doc """
  Per-VirtualObject / Workflow key for this invocation.

  This is the path segment after the service name in `/<Service>/<key>/<handler>`
  and is mirrored by Restate as `StartMessage.key`. For plain Services
  (non-keyed) this is the empty string.
  """
  @spec key(t()) :: String.t()
  def key(%__MODULE__{key: key}), do: key

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

  @doc """
  Clear a state value. No-op for unknown keys (matches Restate semantics).
  """
  @spec clear_state(t(), binary()) :: :ok
  def clear_state(%__MODULE__{pid: pid}, key) when is_binary(key) do
    GenServer.call(pid, {:clear_state, key})
  end

  @doc """
  Sleep for `duration_ms` milliseconds, durably.

  On the first invocation this records a `SleepCommandMessage` and
  suspends the invocation — the runtime persists the journal, waits for
  the timer, and re-invokes the handler. On the resumed invocation the
  recorded sleep entry is replayed and this call returns immediately.

  This call does not return on the first invocation: when the runtime
  schedules the suspension, the handler process is terminated.
  """
  @spec sleep(t(), non_neg_integer()) :: :ok
  def sleep(%__MODULE__{pid: pid}, duration_ms) when is_integer(duration_ms) and duration_ms >= 0 do
    GenServer.call(pid, {:sleep, duration_ms}, :infinity)
  end
end
