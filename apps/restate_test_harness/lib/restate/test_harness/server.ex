defmodule Restate.TestHarness.Server do
  @moduledoc false

  use GenServer

  require Logger

  alias Restate.TestHarness.Instance

  @default_image "docker.restate.dev/restatedev/restate:1.6.2"
  @default_health_timeout_ms 30_000
  @health_poll_interval_ms 250
  @host_gateway_alias "host.docker.internal:host-gateway"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    image = Keyword.get(opts, :image, @default_image)
    ingress_port = Keyword.get_lazy(opts, :ingress_port, &free_port/0)
    admin_port = Keyword.get_lazy(opts, :admin_port, &free_port/0)
    name = Keyword.get(opts, :name, "restate-harness-#{:erlang.unique_integer([:positive])}")
    health_timeout = Keyword.get(opts, :health_timeout_ms, @default_health_timeout_ms)
    env = Keyword.get(opts, :env, [])

    with :ok <- ensure_docker_available(),
         {:ok, container_id} <- docker_run(image, name, ingress_port, admin_port, env) do
      instance = %Instance{
        container_id: container_id,
        image: image,
        ingress_url: "http://localhost:#{ingress_port}",
        admin_url: "http://localhost:#{admin_port}"
      }

      case wait_for_health(instance, health_timeout) do
        :ok ->
          {:ok, %{instance: instance}}

        {:error, reason} ->
          dump_logs(container_id)
          docker_rm(container_id)
          {:stop, {:health_timeout, reason}}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply, state.instance, state}
  end

  @impl true
  def handle_info({:EXIT, _port, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{instance: %Instance{container_id: id}}) do
    docker_rm(id)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp ensure_docker_available do
    case System.cmd("docker", ["version", "--format", "{{.Server.Version}}"], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:docker_unavailable, code, String.trim(out)}}
    end
  rescue
    e in ErlangError -> {:error, {:docker_not_found, Exception.message(e)}}
  end

  defp docker_run(image, name, ingress_port, admin_port, env) do
    args =
      [
        "run",
        "-d",
        "--rm",
        "--name",
        name,
        "--add-host=#{@host_gateway_alias}",
        "-p",
        "#{ingress_port}:8080",
        "-p",
        "#{admin_port}:9070"
      ] ++ env_args(env) ++ [image]

    case System.cmd("docker", args, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, code} ->
        {:error, {:docker_run_failed, code, String.trim(output)}}
    end
  end

  defp env_args(env) do
    Enum.flat_map(env, fn {k, v} -> ["-e", "#{k}=#{v}"] end)
  end

  defp docker_rm(container_id) do
    System.cmd("docker", ["rm", "-f", container_id], stderr_to_stdout: true)
    :ok
  end

  @doc false
  def pause(container_id), do: docker_simple(["pause", container_id])

  @doc false
  def unpause(container_id), do: docker_simple(["unpause", container_id])

  @doc false
  def restart(container_id), do: docker_simple(["restart", container_id])

  defp docker_simple(args) do
    case System.cmd("docker", args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:docker_failed, code, String.trim(out)}}
    end
  end

  defp dump_logs(container_id) do
    case System.cmd("docker", ["logs", "--tail", "100", container_id], stderr_to_stdout: true) do
      {out, _} -> Logger.warning("restate-server logs (last 100 lines):\n#{out}")
    end
  end

  # The Restate container takes a few seconds to come up — partition
  # processor, ingress, admin all bind asynchronously. Poll
  # /restate/health on the admin port until 200 or timeout.
  defp wait_for_health(instance, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll_health(instance, deadline)
  end

  defp do_poll_health(instance, deadline) do
    case Restate.TestHarness.health(instance) do
      :ok ->
        :ok

      {:error, _reason} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :unhealthy}
        else
          Process.sleep(@health_poll_interval_ms)
          do_poll_health(instance, deadline)
        end
    end
  end

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(sock)
    :ok = :gen_tcp.close(sock)
    port
  end
end
