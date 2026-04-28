defmodule Restate.RetryPolicy do
  @moduledoc """
  Retry policy for `Restate.Context.run/3`.

  When a function passed to `ctx.run` raises a non-terminal exception,
  the SDK retries it in-process with exponential backoff. The policy
  controls how many attempts are made and the spacing between them.
  Once the budget is exhausted, the SDK proposes a `Restate.TerminalError`
  as the run's failure — the next replay sees the terminal failure
  deterministically.

  ## Fields

    * `:initial_interval_ms` — delay before the first retry (default 50)
    * `:max_interval_ms`     — cap on the delay between retries (default 10_000)
    * `:factor`              — multiplier applied between retries (default 2.0)
    * `:max_attempts`        — total attempts before giving up. `nil` means
                               retry forever (default — matches Java's
                               `RetryPolicy { initialDelay = ... }` with no
                               `maxAttempts`).

  ## Notes

  Backoff is computed deterministically from the policy + attempt
  index so replays don't need to record per-attempt timing in the
  journal. Only the final ProposeRunCompletion (value or failure) is
  journaled.
  """

  @type t :: %__MODULE__{
          initial_interval_ms: non_neg_integer(),
          max_interval_ms: non_neg_integer(),
          factor: float(),
          max_attempts: pos_integer() | nil
        }

  defstruct initial_interval_ms: 50,
            max_interval_ms: 10_000,
            factor: 2.0,
            max_attempts: nil

  @doc """
  Build a policy from a keyword list. Unknown keys are ignored.
  """
  @spec from_opts(keyword()) :: t()
  def from_opts(opts) when is_list(opts) do
    %__MODULE__{
      initial_interval_ms: Keyword.get(opts, :initial_interval_ms, 50),
      max_interval_ms: Keyword.get(opts, :max_interval_ms, 10_000),
      factor: Keyword.get(opts, :factor, 2.0) * 1.0,
      max_attempts: Keyword.get(opts, :max_attempts)
    }
  end

  @doc """
  True when `attempt` is the last allowed attempt — i.e. the next
  failure should convert to a terminal error rather than retry.
  An attempt count of 1 means we're on the first attempt.
  """
  @spec exhausted?(t(), pos_integer()) :: boolean()
  def exhausted?(%__MODULE__{max_attempts: nil}, _attempt), do: false

  def exhausted?(%__MODULE__{max_attempts: max}, attempt) when is_integer(attempt) do
    attempt >= max
  end

  @doc """
  Backoff delay (ms) before attempt N+1, given a previous attempt N
  (1-based). `delay(p, 1)` is `initial_interval_ms`, `delay(p, 2)` is
  `initial_interval_ms * factor`, capped at `max_interval_ms`.
  """
  @spec delay_ms(t(), pos_integer()) :: non_neg_integer()
  def delay_ms(%__MODULE__{} = p, attempt) when is_integer(attempt) and attempt >= 1 do
    raw = p.initial_interval_ms * :math.pow(p.factor, attempt - 1)
    min(round(raw), p.max_interval_ms)
  end
end
