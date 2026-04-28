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
    case GenServer.call(pid, {:get_state, key}, :infinity) do
      nil ->
        nil

      bytes when is_binary(bytes) ->
        Jason.decode!(bytes)

      {:terminal_error, %Restate.TerminalError{} = exc} ->
        # Cancellation hit during a lazy state fetch — surface to the
        # handler the same way ctx.sleep/call/etc. do.
        raise exc
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
    case GenServer.call(pid, :state_keys, :infinity) do
      keys when is_list(keys) ->
        keys

      {:terminal_error, %Restate.TerminalError{} = exc} ->
        raise exc
    end
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
    case GenServer.call(pid, {:sleep, duration_ms}, :infinity) do
      :ok -> :ok
      {:terminal_error, %Restate.TerminalError{} = exc} -> raise exc
    end
  end

  @doc """
  Deferred-emit variant of `sleep/2`. Records a `SleepCommand` on the
  journal and returns a handle, **without blocking**. Compose with
  `Restate.Awaitable.any/2` / `all/2` to wait on a sleep alongside
  other awaitables — the basis for "await-or-timeout" patterns.

      timer = Restate.Context.timer(ctx, 1_000)
      {id, awakeable} = Restate.Context.awakeable(ctx)
      Restate.Awaitable.any(ctx, [awakeable, timer])
      # → either the awakeable's value or :ok (timer fired first)
  """
  @spec timer(t(), non_neg_integer()) :: {:timer_handle, non_neg_integer()}
  def timer(%__MODULE__{pid: pid}, duration_ms)
      when is_integer(duration_ms) and duration_ms >= 0 do
    GenServer.call(pid, {:start_timer, duration_ms}, :infinity)
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
  Deferred-emit variant of `call/5`. Records a `CallCommand` on the
  journal and returns a handle, **without blocking**. Compose with
  `Restate.Awaitable.any/2` / `all/2` to wait on multiple calls in
  parallel:

      h1 = Restate.Context.call_async(ctx, "Counter", "add", 1, key: "k1")
      h2 = Restate.Context.call_async(ctx, "Counter", "add", 2, key: "k2")
      [r1, r2] = Restate.Awaitable.all(ctx, [h1, h2])
  """
  @spec call_async(t(), String.t(), String.t(), term(), keyword()) ::
          {:call_handle, non_neg_integer(), non_neg_integer()}
  def call_async(%__MODULE__{pid: pid}, service, handler, parameter, opts \\ [])
      when is_binary(service) and is_binary(handler) do
    GenServer.call(
      pid,
      {:start_call,
       %{
         service: service,
         handler: handler,
         parameter: encode_parameter(parameter),
         key: Keyword.get(opts, :key, ""),
         idempotency_key: Keyword.get(opts, :idempotency_key)
       }},
      :infinity
    )
  end

  @doc """
  Fire-and-forget call to another Restate handler. Returns the
  invocation-id string of the spawned invocation.

  In `REQUEST_RESPONSE` protocol mode this still suspends once
  (waiting for the runtime to commit the spawn and tell us the
  invocation id). The cost is one HTTP round-trip; the called
  handler runs to completion independently — we don't wait for its
  result.

  Use `send_async/5` instead when you don't need the invocation id —
  it skips that round-trip entirely, which is the point of fan-out
  workloads.

  ## Arguments

  Same shape as `call/5`. Use this when you want to kick off work
  and continue without blocking on its result.
  """
  @spec send(t(), String.t(), String.t(), term(), keyword()) :: String.t()
  def send(%__MODULE__{pid: pid}, service, handler, parameter, opts \\ [])
      when is_binary(service) and is_binary(handler) do
    case GenServer.call(
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
         ) do
      {:ok, id} when is_binary(id) -> id
      {:terminal_error, %Restate.TerminalError{} = exc} -> raise exc
    end
  end

  @doc """
  Truly fire-and-forget variant of `send/5`: emits the
  `OneWayCallCommandMessage` and returns `:ok` immediately. **Does
  not wait for the runtime to confirm the spawn.** The caller cannot
  see the spawned invocation's id.

  This is the high-concurrency fan-out primitive — see Demo 4. From
  one orchestrator handler you can issue thousands of `send_async`
  calls in a row, each costing essentially zero (one journaled
  command, no HTTP round-trip). When you eventually suspend (e.g.,
  on `await_awakeable/2`), all the spawned invocations run in
  parallel in Restate.

  ## Trade-off vs `send/5`

      send/5         | round-trip per send | returns invocation_id
      send_async/5   | zero round-trips    | returns :ok
  """
  @spec send_async(t(), String.t(), String.t(), term(), keyword()) :: :ok
  def send_async(%__MODULE__{pid: pid}, service, handler, parameter, opts \\ [])
      when is_binary(service) and is_binary(handler) do
    GenServer.call(
      pid,
      {:send_async,
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

  # JSON-encode the parameter. Elixir strings are binaries, so a naive
  # binary-passthrough turns `"sign_1abc"` into the wire bytes `sign_1abc`
  # (unquoted) — which `Jason.decode!` on the receiver chokes on. The
  # `{:raw, bytes}` opt-out is for callers that already hold pre-encoded
  # wire bytes (e.g. the Proxy conformance handler forwards opaque
  # JSON-encoded byte arrays from the test client).
  defp encode_parameter({:raw, bytes}) when is_binary(bytes), do: bytes
  defp encode_parameter(term), do: Jason.encode!(term)

  @doc """
  Create an awakeable. Returns `{awakeable_id, handle}` where:

    * `awakeable_id` — an opaque string of the form `"prom_1<base64>"`
      that other handlers (or external code) can use to complete this
      awakeable via `complete_awakeable/3` or `reject_awakeable/4`.
      Pass it across the wire freely.
    * `handle` — opaque token for `await_awakeable/2` later in this
      same handler.

  ## Use

      {id, handle} = Restate.Context.awakeable(ctx)
      Restate.Context.call(ctx, "AwakeableHolder", "hold", id, key: "k")
      # ... external code completes it ...
      value = Restate.Context.await_awakeable(ctx, handle)

  Awakeables are signal-id-based under the hood: the SDK allocates a
  signal id (starting from 17 — Restate reserves 1–16), encodes
  `(StartMessage.id, signal_id)` as the awakeable_id, and waits on a
  matching `SignalNotificationMessage` when `await_awakeable/2` is
  called.
  """
  @spec awakeable(t()) :: {String.t(), {:awakeable_handle, non_neg_integer()}}
  def awakeable(%__MODULE__{pid: pid}) do
    {:ok, {id, signal_id}} = GenServer.call(pid, :awakeable, :infinity)
    {id, {:awakeable_handle, signal_id}}
  end

  @doc """
  Await the result of an awakeable created by `awakeable/1`.
  Suspends the invocation until the awakeable is completed
  externally; on resume returns the supplied value (or raises
  `Restate.TerminalError` if rejected).
  """
  @spec await_awakeable(t(), {:awakeable_handle, non_neg_integer()}) :: term()
  def await_awakeable(%__MODULE__{pid: pid}, {:awakeable_handle, signal_id}) do
    case GenServer.call(pid, {:await_awakeable, signal_id}, :infinity) do
      {:ok, value} -> value
      {:terminal_error, %Restate.TerminalError{} = exc} -> raise exc
    end
  end

  @doc """
  Complete an awakeable with a success value. The target invocation
  resumes with this value the next time it executes. No-op locally if
  the awakeable has already been completed.
  """
  @spec complete_awakeable(t(), String.t(), term()) :: :ok
  def complete_awakeable(%__MODULE__{pid: pid}, awakeable_id, value)
      when is_binary(awakeable_id) do
    GenServer.call(pid, {:complete_awakeable, awakeable_id, {:value, encode_parameter(value)}})
  end

  @doc """
  Complete an awakeable with a terminal failure. The target invocation
  raises `Restate.TerminalError{code, message}` on resume.
  """
  @spec reject_awakeable(t(), String.t(), non_neg_integer(), String.t()) :: :ok
  def reject_awakeable(%__MODULE__{pid: pid}, awakeable_id, code, message)
      when is_binary(awakeable_id) and is_integer(code) and is_binary(message) do
    GenServer.call(
      pid,
      {:complete_awakeable, awakeable_id, {:failure, code, message}}
    )
  end

  @doc """
  Block on a Workflow durable promise and return its resolved value.

  Promises are scoped to the Workflow's key — the same `name` resolves
  to the same promise across the workflow handler and its `@Shared`
  helpers. This call records a `GetPromiseCommand` and suspends until
  the promise is set (via `complete_promise/3`) or rejected (via
  `reject_promise/4`).

  Raises `Restate.TerminalError` if the promise was rejected.
  """
  @spec get_promise(t(), String.t()) :: term()
  def get_promise(%__MODULE__{pid: pid}, name) when is_binary(name) do
    case GenServer.call(pid, {:promise_get, name}, :infinity) do
      {:ok, value} -> value
      {:terminal_error, %Restate.TerminalError{} = exc} -> raise exc
    end
  end

  @doc """
  Non-blocking probe of a Workflow durable promise.

  Returns `:pending` if the promise hasn't been set yet, `{:ok, v}`
  if resolved with a value, or `{:terminal_error, exc}` if rejected.
  Useful for "the await is over, verify we got here via the promise
  rather than a spurious resume" assertions.
  """
  @spec peek_promise(t(), String.t()) :: :pending | {:ok, term()} | {:terminal_error, Restate.TerminalError.t()}
  def peek_promise(%__MODULE__{pid: pid}, name) when is_binary(name) do
    GenServer.call(pid, {:promise_peek, name}, :infinity)
  end

  @doc """
  Resolve a Workflow durable promise with `value`.

  Typically called from a `@Shared` handler so external code can
  unblock the workflow's `get_promise/2` await. Returns `:ok`; raises
  `Restate.TerminalError` if the runtime refuses (e.g. the promise
  was already rejected and a value can't replace it).
  """
  @spec complete_promise(t(), String.t(), term()) :: :ok
  def complete_promise(%__MODULE__{pid: pid}, name, value) when is_binary(name) do
    case GenServer.call(pid, {:promise_complete, name, {:value, encode_parameter(value)}}, :infinity) do
      :ok -> :ok
      {:terminal_error, %Restate.TerminalError{} = exc} -> raise exc
    end
  end

  @doc """
  Reject a Workflow durable promise with a terminal failure.

  The waiting `get_promise/2` raises `Restate.TerminalError{code, message}`.
  """
  @spec reject_promise(t(), String.t(), non_neg_integer(), String.t()) :: :ok
  def reject_promise(%__MODULE__{pid: pid}, name, code, message)
      when is_binary(name) and is_integer(code) and is_binary(message) do
    case GenServer.call(
           pid,
           {:promise_complete, name, {:failure, code, message}},
           :infinity
         ) do
      :ok -> :ok
      {:terminal_error, %Restate.TerminalError{} = exc} -> raise exc
    end
  end

  @doc """
  Cancel another invocation by id.

  Emits a `SendSignalCommandMessage` carrying the built-in CANCEL
  signal (`signal_id = 1` per `BuiltInSignal` in protocol.proto). The
  Restate runtime delivers it to the target invocation; the target's
  next suspending Context op (`sleep`, `call`, `send`, `await_awakeable`,
  `run`) raises `Restate.TerminalError{code: 409, message: "cancelled"}`,
  which terminates the target with `OutputCommandMessage{failure}`
  and cascades through any in-flight call tree.

  Fire-and-forget: returns `:ok` immediately. The cancellation does
  not need to be acknowledged on this stream.

  ## Use

      id = Restate.Context.send(ctx, "Worker", "longJob", arg, key: "k")
      # ... later ...
      Restate.Context.cancel_invocation(ctx, id)

  Use the invocation id returned by `send/5` (or by an out-of-band
  admin call). For cancelling *this* invocation, raise
  `Restate.TerminalError` directly — that's the same wire effect
  with no round-trip.
  """
  @spec cancel_invocation(t(), String.t()) :: :ok
  def cancel_invocation(%__MODULE__{pid: pid}, invocation_id) when is_binary(invocation_id) do
    GenServer.call(pid, {:send_signal, invocation_id, 1})
  end

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
  def run(%__MODULE__{} = ctx, fun) when is_function(fun, 0), do: run(ctx, fun, [])

  @doc """
  `run/2` with an explicit retry policy. `opts` is a keyword list
  that builds a `Restate.RetryPolicy`:

      Restate.Context.run(ctx, &flaky_call/0,
        max_attempts: 3,
        initial_interval_ms: 100,
        factor: 2.0
      )

  When the function raises a non-terminal exception, the SDK
  retries it in-process with exponential backoff. Once the budget is
  exhausted (default: infinite), the SDK proposes a
  `Restate.TerminalError{code: 500, message: "ctx.run exhausted retries: ..."}`
  as the run's failure — the next replay sees the terminal failure
  deterministically.

  `Restate.TerminalError` raised inside the function is *not*
  retried — it's journaled immediately as the run's failure. Use it
  for "give up forever" failures (validation, business-logic dead
  ends).
  """
  @spec run(t(), (-> term()), keyword()) :: term()
  def run(%__MODULE__{pid: pid} = ctx, fun, opts)
      when is_function(fun, 0) and is_list(opts) do
    policy = Restate.RetryPolicy.from_opts(opts)

    case GenServer.call(pid, :start_run, :infinity) do
      {:replay_value, value} ->
        value

      {:replay_failure, %Restate.TerminalError{} = exc} ->
        raise exc

      {:terminal_error, %Restate.TerminalError{} = exc} ->
        # Invocation cancelled before this run could execute — skip
        # the side-effecting function and propagate the cancellation.
        raise exc

      {:execute, cid} ->
        do_run_with_retry(ctx, cid, fun, policy, 1)
    end
  end

  # Synchronous in-process retry loop. On success, propose value +
  # suspend (handler process is then killed via the GenServer's
  # `:stop`, so any code after the propose is unreachable). On
  # `Restate.TerminalError`, propose the failure + suspend — no
  # retry. On any other exception, either retry (after backoff) or
  # exhaust (propose synthesized terminal failure + suspend). The
  # function value is returned only on the replay path through
  # `run/3`'s outer `case`; on the first execution this function
  # never returns.
  defp do_run_with_retry(%__MODULE__{pid: pid} = ctx, cid, fun, policy, attempt) do
    try do
      result = fun.()
      GenServer.call(pid, {:propose_run_and_suspend, cid, {:value, result}}, :infinity)
      # Unreachable on first execution (handler killed when GenServer
      # suspends). The value below is only here for type-completeness;
      # the *real* return value comes from the replay path.
      result
    rescue
      e in Restate.TerminalError ->
        GenServer.call(pid, {:propose_run_and_suspend, cid, {:failure, e}}, :infinity)
        reraise e, __STACKTRACE__

      e ->
        if Restate.RetryPolicy.exhausted?(policy, attempt) do
          terminal = %Restate.TerminalError{
            code: 500,
            message: "ctx.run exhausted retries: " <> Exception.message(e)
          }

          GenServer.call(pid, {:propose_run_and_suspend, cid, {:failure, terminal}}, :infinity)
          reraise terminal, __STACKTRACE__
        else
          Process.sleep(Restate.RetryPolicy.delay_ms(policy, attempt))
          do_run_with_retry(ctx, cid, fun, policy, attempt + 1)
        end
    end
  end
end
