defmodule Restate.TestHarness.Sdk do
  @moduledoc """
  BEAM-side lifecycle control for the SDK runtime under test.

  Wraps `Application.put_env`, `ensure_all_started`, and `stop` to give
  fault-injection tests a programmatic equivalent of `kubectl delete
  pod --force` — simulate the handler crashing and coming back, and
  watch Restate replay the journal through the recovered runtime.

  ## Pattern

      {:ok, _} = Sdk.start(handler_app: :restate_example_greeter)
      port = Sdk.port()

      # ... start a long-running invocation ...

      :ok = Sdk.crash()
      Process.sleep(500)
      {:ok, _} = Sdk.recover()

      # The invocation completes via journal replay against the
      # restarted handler app.

  ## Notes

  Stopping `:restate_server` also unbinds the Bandit listener and
  drops every in-flight `Restate.Server.Invocation` GenServer. From
  Restate's perspective this is identical to a node going dark mid-
  request: the in-flight HTTP call fails, but the journal remains
  on Restate's side and the next `POST /invoke/...` (after recovery)
  carries the full replay journal so the handler resumes.

  This module assumes a single SDK runtime per BEAM (the harness's
  default — only one `Restate.Server.Endpoint` Bandit listener can
  bind a port at a time). A multi-tenant test harness is a v3
  concern.
  """

  @default_handler_apps [:restate_example_greeter]
  @port_key {__MODULE__, :port}
  @apps_key {__MODULE__, :apps}

  @doc """
  Boot the SDK runtime + handler apps on a free port. Subsequent
  calls to `port/0` return that port.

  Options:

    * `:handler_app` — single app to start (defaults to
      `:restate_example_greeter`).
    * `:handler_apps` — list of apps to start in order. Wins over
      `:handler_app` if both are given.
    * `:port` — bind to a specific port instead of a free one.
  """
  @spec start(keyword()) :: {:ok, %{port: pos_integer(), apps: [atom()]}} | {:error, term()}
  def start(opts \\ []) do
    apps =
      Keyword.get(opts, :handler_apps) ||
        [Keyword.get(opts, :handler_app, hd(@default_handler_apps))]

    if running?(:restate_server) do
      port = Application.fetch_env!(:restate_server, :port)
      :persistent_term.put(@port_key, port)
      :persistent_term.put(@apps_key, apps)
      {:ok, %{port: port, apps: apps}}
    else
      port = Keyword.get_lazy(opts, :port, &free_port/0)
      Application.put_env(:restate_server, :port, port)

      case start_apps(apps) do
        :ok ->
          :persistent_term.put(@port_key, port)
          :persistent_term.put(@apps_key, apps)
          {:ok, %{port: port, apps: apps}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp running?(app) do
    Enum.any?(Application.started_applications(), fn {a, _, _} -> a == app end)
  end

  @doc "Return the port the SDK is bound to."
  @spec port() :: pos_integer()
  def port, do: :persistent_term.get(@port_key)

  @doc """
  Stop the SDK runtime — equivalent to a pod kill from Restate's
  perspective. Drops the Bandit listener and every in-flight
  `Restate.Server.Invocation`. Use `recover/0` to bring the runtime
  back; Restate will replay journals on the next invocation.
  """
  @spec crash() :: :ok | {:error, term()}
  def crash do
    apps = current_apps()

    apps
    |> Enum.reverse()
    |> Enum.reduce_while(:ok, fn app, :ok ->
      case Application.stop(app) do
        :ok -> {:cont, :ok}
        {:error, {:not_started, ^app}} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {app, reason}}}
      end
    end)
  end

  @doc """
  Restart the SDK + handler apps. The handler apps' `start/2`
  callbacks re-register their services on the (fresh) registry.
  """
  @spec recover() :: {:ok, [atom()]} | {:error, term()}
  def recover do
    apps = current_apps()

    case start_apps(apps) do
      :ok -> {:ok, apps}
      other -> other
    end
  end

  @doc """
  Convenience: run `fun` while the SDK is crashed, then recover.
  Use to exercise journal-replay scenarios without writing the
  crash/recover dance by hand.

      Sdk.with_crash(fn -> Process.sleep(500) end)
  """
  @spec with_crash((-> any())) :: {:ok, any()} | {:error, term()}
  def with_crash(fun) when is_function(fun, 0) do
    with :ok <- crash() do
      result = fun.()

      case recover() do
        {:ok, _apps} -> {:ok, result}
        other -> other
      end
    end
  end

  defp start_apps(apps) do
    Enum.reduce_while(apps, :ok, fn app, :ok ->
      case Application.ensure_all_started(app) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {app, reason}}}
      end
    end)
  end

  defp current_apps do
    case :persistent_term.get(@apps_key, :undefined) do
      :undefined -> @default_handler_apps
      apps -> apps
    end
  end

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(sock)
    :ok = :gen_tcp.close(sock)
    port
  end
end
