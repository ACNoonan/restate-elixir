defmodule Restate.Telemetry do
  @moduledoc """
  Telemetry events emitted by the Restate SDK runtime.

  All events follow the [`:telemetry`](https://hexdocs.pm/telemetry)
  convention. Attach to them once at app boot and forward to
  Prometheus / OpenTelemetry / Datadog / Logger / anywhere.

  ## Events

  ### `[:restate, :invocation, :start]`

  Emitted when an invocation arrives at `POST /invoke/:service/:handler`.

  | Measurements | |
  | --- | --- |
  | `system_time` | `System.system_time/0` at start |
  | `monotonic_time` | `System.monotonic_time/0` at start |

  | Metadata | |
  | --- | --- |
  | `service` | service name (string) |
  | `handler` | handler name (string) |
  | `telemetry_span_context` | span correlation ref (set by `:telemetry.span`) |

  ### `[:restate, :invocation, :stop]`

  Emitted when the invocation finishes — handler returned, raised,
  or suspended. Pairs with `:start` via `telemetry_span_context`.

  | Measurements | |
  | --- | --- |
  | `duration` | wall-clock duration in `:native` time units |
  | `monotonic_time` | `System.monotonic_time/0` at stop |

  | Metadata | |
  | --- | --- |
  | `service` | service name |
  | `handler` | handler name |
  | `outcome` | one of `:value`, `:terminal_failure`, `:error`, `:suspended`, `:journal_mismatch` |
  | `response_bytes` | size of the framed wire response sent to Restate |
  | `telemetry_span_context` | span correlation ref |

  ### `[:restate, :invocation, :exception]`

  Emitted when an unexpected exception escapes the dispatch — i.e. a
  bug in the SDK itself, not a handler-raised error (those are caught
  and reported via `:stop` with `outcome: :error`).

  Standard `:telemetry.span` exception metadata: `kind`, `reason`,
  `stacktrace`, plus the `service`/`handler` start-metadata.

  ### `[:restate, :invocation, :replay_complete]`

  Emitted once per invocation, when the handler catches up to the
  head of the replay journal and transitions from `:replaying` to
  `:processing`. Skipped entirely for invocations that started with
  no recorded journal (first run).

  | Measurements | |
  | --- | --- |
  | `monotonic_time` | `System.monotonic_time/0` |
  | `replayed_commands` | count of recorded commands consumed during replay |

  | Metadata | |
  | --- | --- |
  | `service` | service name |
  | `handler` | handler name |

  ### `[:restate, :invocation, :journal_mismatch]`

  Emitted when the SDK detects a journal mismatch — the handler asked
  for command type X but the recorded journal's next entry is type
  Y, or the journal is exhausted. Surfaced as protocol code 570; the
  Restate runtime stops the invocation and surfaces it to the
  operator.

  | Measurements | |
  | --- | --- |
  | `monotonic_time` | `System.monotonic_time/0` |

  | Metadata | |
  | --- | --- |
  | `service` | service name |
  | `handler` | handler name |
  | `code` | protocol error code (570 = JOURNAL_MISMATCH) |
  | `message` | human-readable error message |
  | `command_index` | zero-based index of the failing command |

  ## Attaching

  Attach all events at application boot:

      :telemetry.attach_many(
        "my-app-restate",
        [
          [:restate, :invocation, :start],
          [:restate, :invocation, :stop],
          [:restate, :invocation, :exception],
          [:restate, :invocation, :replay_complete],
          [:restate, :invocation, :journal_mismatch]
        ],
        &MyApp.RestateMetrics.handle_event/4,
        nil
      )

  Or use `Telemetry.Metrics` to define counters / histograms once and
  let any reporter (PromEx, `telemetry_metrics_prometheus`,
  `opentelemetry_telemetry`) consume them.

  ## Conventions

  * `service` and `handler` are always present on every event (modulo
    the rare case where the request 404s before dispatch — those
    events do not fire).
  * Wall-clock durations use the `:native` time unit. Convert with
    `System.convert_time_unit(duration, :native, :microsecond)` at
    the reporting site.
  * Metadata is intentionally minimal. If you need fields not listed
    here, open an issue with the use case — the surface is meant to
    grow deliberately, not by accretion.
  """
end
