defmodule Restate.Server.Registry do
  @moduledoc """
  In-memory registry of services exposed by this Restate endpoint.

  Apps register their services on start (typically from
  `MyApp.Application.start/2`). Lookup happens on the request hot path so
  the registry is backed by `:persistent_term` rather than a GenServer —
  no message-passing overhead per invocation.

  A service is a map of:
      %{name: binary,
        type: :service | :virtual_object | :workflow,
        handlers: [%{name: binary,
                     type: :exclusive | :shared | :workflow | nil,
                     mfa: {module, atom, arity}}]}
  """

  @key {__MODULE__, :services}
  @last_registered_key {__MODULE__, :last_registered_at}

  # When `/discover` arrives, the runtime expects a complete service
  # list. If the host app is still calling `register_service/1` from
  # one or more `Application.start/2` callbacks (umbrella apps in a
  # release boot in dependency order, which puts `restate_server`
  # *before* the apps that register handlers), discovery can race and
  # respond with a partial manifest — and the runtime then 404s on
  # the services that hadn't registered yet.
  #
  # `wait_for_quiescence/2` polls the registry until either no new
  # services have been registered for `idle_ms` milliseconds, or
  # `max_ms` total has elapsed. Cheap (`:persistent_term.get/2` is
  # O(1) and lock-free) and deterministic. Default knobs are tuned
  # for typical umbrella boots (~50ms between Application.start
  # callbacks).
  @default_idle_ms 200
  @default_max_ms 2_000

  @doc "Register a service. Replaces any previous registration with the same name."
  @spec register_service(map()) :: :ok
  def register_service(%{name: name} = service) when is_binary(name) do
    services =
      list_services()
      |> Enum.reject(&(&1.name == name))
      |> List.insert_at(-1, service)

    :persistent_term.put(@key, services)
    :persistent_term.put(@last_registered_key, monotonic_ms())
    :ok
  end

  @doc "All registered services, in registration order."
  @spec list_services() :: [map()]
  def list_services, do: :persistent_term.get(@key, [])

  @doc "Wipe the registry. Test-only — not part of the public surface."
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@key)
    :persistent_term.erase(@last_registered_key)
    :ok
  end

  @doc """
  Block until the registry has been quiet (no `register_service/1` calls)
  for `idle_ms` milliseconds, or until `max_ms` total has elapsed.

  Called from the discovery endpoint to avoid responding with a partial
  service list during umbrella boot. Returns `:ok` either way — callers
  can rely on "we waited as long as is reasonable" rather than
  "registration is provably done" (which the SDK can't know in general).

  Idempotent: when registration has long since settled, the first
  `idle_ms` poll exits immediately.
  """
  @spec wait_for_quiescence(non_neg_integer(), non_neg_integer()) :: :ok
  def wait_for_quiescence(idle_ms \\ @default_idle_ms, max_ms \\ @default_max_ms) do
    deadline = monotonic_ms() + max_ms
    do_wait_for_quiescence(idle_ms, deadline)
  end

  defp do_wait_for_quiescence(idle_ms, deadline) do
    last = :persistent_term.get(@last_registered_key, 0)
    now = monotonic_ms()

    cond do
      # No registrations at all — assume the host has nothing to register
      # (this is the typical test-bench case and we don't want to add
      # latency there).
      last == 0 ->
        :ok

      # Quiet long enough; we're done.
      now - last >= idle_ms ->
        :ok

      # Past the absolute deadline; give up waiting and proceed.
      now >= deadline ->
        :ok

      true ->
        # Sleep for the smaller of (remaining idle gap, remaining
        # deadline) so we wake exactly when we'd transition.
        remaining_idle = idle_ms - (now - last)
        remaining_deadline = deadline - now
        Process.sleep(min(remaining_idle, remaining_deadline))
        do_wait_for_quiescence(idle_ms, deadline)
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  @doc """
  Look up a handler by `(service_name, handler_name)`.

  Returns the handler map or `:not_found`.
  """
  @spec lookup_handler(binary(), binary()) :: map() | :not_found
  def lookup_handler(service_name, handler_name) do
    with %{handlers: handlers} <- find_service(service_name),
         %{} = handler <- Enum.find(handlers, &(&1.name == handler_name)) do
      handler
    else
      _ -> :not_found
    end
  end

  defp find_service(service_name) do
    Enum.find(list_services(), &(&1.name == service_name))
  end
end
