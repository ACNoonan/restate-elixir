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

  @doc "Register a service. Replaces any previous registration with the same name."
  @spec register_service(map()) :: :ok
  def register_service(%{name: name} = service) when is_binary(name) do
    services =
      list_services()
      |> Enum.reject(&(&1.name == name))
      |> List.insert_at(-1, service)

    :persistent_term.put(@key, services)
    :ok
  end

  @doc "All registered services, in registration order."
  @spec list_services() :: [map()]
  def list_services, do: :persistent_term.get(@key, [])

  @doc "Wipe the registry. Test-only — not part of the public surface."
  @spec reset() :: :ok
  def reset, do: :persistent_term.erase(@key) && :ok

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
