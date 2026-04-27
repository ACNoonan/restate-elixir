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

  @doc "Clear every state value for this VirtualObject key."
  @spec clear_all_state(t()) :: :ok
  def clear_all_state(%__MODULE__{pid: pid}) do
    GenServer.call(pid, :clear_all_state)
  end

  @doc """
  List the keys of every state entry currently set for this
  VirtualObject. Read-only — does not emit a journal entry. Reads
  from the eager state map seeded by `StartMessage.state_map` plus
  any local writes made earlier in this invocation.
  """
  @spec state_keys(t()) :: [binary()]
  def state_keys(%__MODULE__{pid: pid}) do
    GenServer.call(pid, :state_keys)
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

  @doc """
  Synchronous request/reply call to another Restate handler. Durable —
  the journal records the call; on replay the recorded result is
  returned without re-invoking the target.

  ## Arguments

    * `service` — service name as registered in the manifest.
    * `handler` — handler name on that service.
    * `parameter` — JSON-encodable term; sent to the target as the
      handler input. (For raw bytes, encode them yourself and pass
      a binary; this SDK's default is JSON.)
    * `opts`:
      * `key` — required for `:virtual_object` / `:workflow` targets
        (the per-key path segment); empty string for plain Services.
      * `idempotency_key` — opaque string the runtime uses to dedupe.

  Returns the JSON-decoded response. If the target handler raised
  `Restate.TerminalError`, this call raises a fresh
  `Restate.TerminalError` here too — terminal failures propagate
  through the call chain so the originating ingress client sees them.

  Like `sleep/2`, this call does not return on the first execution
  pass — the SDK suspends and the runtime re-invokes the handler
  with the call's result in the journal. On the resumed execution
  the call returns the result.
  """
  @spec call(t(), String.t(), String.t(), term(), keyword()) :: term()
  def call(%__MODULE__{pid: pid}, service, handler, parameter, opts \\ [])
      when is_binary(service) and is_binary(handler) do
    case GenServer.call(
           pid,
           {:call,
            %{
              service: service,
              handler: handler,
              parameter: encode_parameter(parameter),
              key: Keyword.get(opts, :key, ""),
              idempotency_key: Keyword.get(opts, :idempotency_key)
            }},
           :infinity
         ) do
      {:ok, value} -> value
      {:terminal_error, %Restate.TerminalError{} = exc} -> raise exc
    end
  end

  @doc """
  Fire-and-forget call to another Restate handler. Returns the
  invocation-id string of the spawned invocation.

  In `REQUEST_RESPONSE` protocol mode this still suspends once
  (waiting for the runtime to commit the spawn and tell us the
  invocation id). The cost is one HTTP round-trip; the called
  handler runs to completion independently — we don't wait for its
  result.

  ## Arguments

  Same shape as `call/5`. Use this when you want to kick off work
  and continue without blocking on its result.
  """
  @spec send(t(), String.t(), String.t(), term(), keyword()) :: String.t()
  def send(%__MODULE__{pid: pid}, service, handler, parameter, opts \\ [])
      when is_binary(service) and is_binary(handler) do
    GenServer.call(
      pid,
      {:send,
       %{
         service: service,
         handler: handler,
         parameter: encode_parameter(parameter),
         key: Keyword.get(opts, :key, ""),
         idempotency_key: Keyword.get(opts, :idempotency_key),
         invoke_at_ms: Keyword.get(opts, :invoke_at_ms, 0)
       }},
      :infinity
    )
  end

  defp encode_parameter(bytes) when is_binary(bytes), do: bytes
  defp encode_parameter(term), do: Jason.encode!(term)

  @doc """
  Run a side-effecting function durably. The result is journaled so
  future replays of this invocation use the recorded value rather
  than re-executing the function.

  Use this for any non-deterministic operation: random IDs, current
  time, calls to external APIs, file reads. The function runs at
  most once per logical "run" — even across crashes / pod restarts.

  ## Failure semantics

    * Function returns normally → result is journaled; future
      replays return the same value without re-running the function.
    * Function raises `Restate.TerminalError` → terminal failure is
      journaled; future replays re-raise the same error. The
      surrounding handler invocation completes with an
      `OutputCommandMessage{failure}` unless the user catches it.
    * Function raises any other exception → not journaled. The SDK
      emits `ErrorMessage{500}` (retryable); Restate retries the
      whole invocation, which may run the function again.

  ## Notes

    * The function runs in the handler process (not the Invocation
      GenServer); it can call back into the Context for state ops
      that come *before* the run completes, but a re-entrant
      `Restate.Context.run/2` from inside the function is not
      supported.
    * The result must be JSON-encodable. Raw binaries pass through
      unchanged (use them for opaque blob results).
  """
  @spec run(t(), (-> term())) :: term()
  def run(%__MODULE__{pid: pid}, fun) when is_function(fun, 0) do
    case GenServer.call(pid, :start_run, :infinity) do
      {:replay_value, value} ->
        value

      {:replay_failure, %Restate.TerminalError{} = exc} ->
        raise exc

      {:execute, cid} ->
        try do
          result = fun.()
          :ok = GenServer.call(pid, {:propose_run, cid, {:value, result}}, :infinity)
          result
        rescue
          e in Restate.TerminalError ->
            :ok = GenServer.call(pid, {:propose_run, cid, {:failure, e}}, :infinity)
            reraise e, __STACKTRACE__
        end
    end
  end
end
