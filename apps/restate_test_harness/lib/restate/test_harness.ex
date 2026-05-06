defmodule Restate.TestHarness do
  @moduledoc """
  Programmatic lifecycle for `restate-server` Docker containers, plus
  admin-API + ingress helpers.

  ## Quickstart

      {:ok, harness} = Restate.TestHarness.start_link()
      instance = Restate.TestHarness.info(harness)

      :ok = Application.put_env(:restate_server, :port, 9080)
      {:ok, _} = Application.ensure_all_started(:restate_server)
      Restate.Server.Registry.register_service(MyHandler)

      :ok = Restate.TestHarness.register_deployment(instance,
              uri: "http://host.docker.internal:9080",
              use_http_11: true)

      {:ok, %{status: 200, body: body}} =
        Restate.TestHarness.invoke(instance, "MyService/greet", %{"name" => "world"})

      Restate.TestHarness.stop(harness)

  See `Restate.TestHarness.Case` for the ExUnit template that wraps
  this in a `setup` block.
  """

  alias Restate.TestHarness.Server

  defmodule Instance do
    @moduledoc """
    Connection details for a running `restate-server` container.
    """

    @enforce_keys [:container_id, :ingress_url, :admin_url]
    defstruct [:container_id, :ingress_url, :admin_url, :image]

    @type t :: %__MODULE__{
            container_id: String.t(),
            ingress_url: String.t(),
            admin_url: String.t(),
            image: String.t()
          }
  end

  @default_image "docker.restate.dev/restatedev/restate:1.6.2"
  @health_timeout_ms 30_000
  @finch Restate.TestHarness.Finch

  @doc """
  Start a Restate container and return a GenServer pid that owns its
  lifecycle. The container is torn down when the pid stops.

  Options:

    * `:image` (string) — container image to run. Defaults to
      `#{@default_image}`. Use this to test against a specific server
      version (e.g. for a multi-version compatibility matrix).
    * `:ingress_port` (integer) — host port for the Restate ingress
      (container :8080). Defaults to a free port allocated at start.
    * `:admin_port` (integer) — host port for the admin API
      (container :9070). Defaults to a free port allocated at start.
    * `:name` (string) — container name. Defaults to a unique
      `restate-harness-<n>` value.
    * `:health_timeout_ms` (integer) — how long to wait for
      `/restate/health` to return 200 before failing start.
      Defaults to #{@health_timeout_ms}.
    * `:env` (list of `{key, value}`) — extra env vars passed to
      `docker run -e`.
  """
  def start_link(opts \\ []) do
    Server.start_link(opts)
  end

  @doc "Return the connection details for a running harness."
  @spec info(GenServer.server()) :: Instance.t()
  def info(server), do: GenServer.call(server, :info)

  @doc "Stop the harness and tear down the container."
  def stop(server), do: GenServer.stop(server)

  @doc """
  Register a handler endpoint with the running Restate server via the
  admin API.

  Required: `:uri` — the URL Restate uses to reach the SDK. From inside
  the container that means `http://host.docker.internal:<sdk_port>`.

  Optional flags map to `RegisterDeploymentRequest` in the admin API:
  `:use_http_11`, `:force` (default `true`), `:breaking`, `:dry_run`,
  `:additional_headers`.
  """
  @spec register_deployment(Instance.t(), keyword()) :: :ok | {:error, term()}
  def register_deployment(%Instance{admin_url: admin_url}, opts) do
    uri = Keyword.fetch!(opts, :uri)

    payload =
      opts
      |> Keyword.take([:use_http_11, :force, :breaking, :dry_run, :additional_headers])
      |> Map.new()
      |> Map.put(:uri, uri)
      |> Map.put_new(:force, true)

    case post_json("#{admin_url}/deployments", payload) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  POST a JSON body to `<ingress>/<path>` and return the parsed response.

  `path` is the part after the ingress base, e.g.
  `"Greeter/world/greet"` or `"NoisyNeighbor/abc/slow_op"`.
  """
  @spec invoke(Instance.t(), String.t(), term(), keyword()) ::
          {:ok, %{status: integer(), body: term(), headers: list()}} | {:error, term()}
  def invoke(%Instance{ingress_url: ingress_url}, path, body, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    extra_headers = Keyword.get(opts, :headers, [])
    headers = [{"content-type", "application/json"} | extra_headers]
    encoded = Jason.encode!(body)

    request = Finch.build(:post, "#{ingress_url}/#{path}", headers, encoded)

    case Finch.request(request, @finch, receive_timeout: timeout) do
      {:ok, %Finch.Response{status: status, body: resp_body, headers: resp_headers}} ->
        {:ok,
         %{
           status: status,
           body: maybe_decode_json(resp_body, resp_headers),
           headers: resp_headers
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Pause the Restate container (`docker pause`). The server's processes
  are SIGSTOPped; in-flight HTTP connections hang. Use to simulate a
  network partition or unresponsive Restate node.
  """
  @spec pause(Instance.t()) :: :ok | {:error, term()}
  def pause(%Instance{container_id: id}), do: Server.pause(id)

  @doc "Resume a paused container (`docker unpause`)."
  @spec unpause(Instance.t()) :: :ok | {:error, term()}
  def unpause(%Instance{container_id: id}), do: Server.unpause(id)

  @doc """
  Restart the container (`docker restart`). Cold-restarts the Restate
  process. With the default in-memory metadata store this loses
  registered deployments and journaled state — useful for testing
  what survives a Restate crash in volatile-storage configurations.
  Waits up to 30s for the admin API to come back healthy before
  returning.
  """
  @spec restart(Instance.t()) :: :ok | {:error, term()}
  def restart(%Instance{} = instance) do
    with :ok <- Server.restart(instance.container_id) do
      wait_for_health(instance, 30_000)
    end
  end

  defp wait_for_health(instance, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_health(instance, deadline)
  end

  defp poll_health(instance, deadline) do
    case health(instance) do
      :ok ->
        :ok

      {:error, _} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :unhealthy_after_restart}
        else
          Process.sleep(250)
          poll_health(instance, deadline)
        end
    end
  end

  @doc """
  Fire-and-forget invocation. POSTs to `<ingress>/<path>/send` and
  returns `{:ok, invocation_id}` immediately. Pair with `attach/3`
  to await the result later — useful when the test needs to do
  something (e.g. crash the SDK) while the invocation is in flight.
  """
  @spec send_async(Instance.t(), String.t(), term(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def send_async(%Instance{ingress_url: ingress_url}, path, body, opts \\ []) do
    headers = [{"content-type", "application/json"} | Keyword.get(opts, :headers, [])]
    encoded = Jason.encode!(body)
    url = "#{ingress_url}/#{path}/send"
    request = Finch.build(:post, url, headers, encoded)

    case Finch.request(request, @finch, receive_timeout: 10_000) do
      {:ok, %Finch.Response{status: status, body: resp_body, headers: resp_headers}}
      when status in 200..299 ->
        case maybe_decode_json(resp_body, resp_headers) do
          %{"invocationId" => id} -> {:ok, id}
          other -> {:error, {:unexpected_send_response, other}}
        end

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Block on a previously-sent invocation until it completes, via the
  ingress's `/restate/invocation/<id>/attach` endpoint. Default
  timeout 60 s — generous, since the SDK may have crashed and be
  recovering.
  """
  @spec attach(Instance.t(), String.t(), keyword()) ::
          {:ok, %{status: integer(), body: term()}} | {:error, term()}
  def attach(%Instance{ingress_url: ingress_url}, invocation_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    url = "#{ingress_url}/restate/invocation/#{invocation_id}/attach"
    request = Finch.build(:get, url)

    case Finch.request(request, @finch, receive_timeout: timeout) do
      {:ok, %Finch.Response{status: status, body: body, headers: headers}} ->
        {:ok, %{status: status, body: maybe_decode_json(body, headers), headers: headers}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Hit the admin `/health` endpoint. Returns `:ok` or `{:error, reason}`.

  Restate exposes `/health` on the admin port (default :9070) and a
  separate `/restate/health` on the ingress port (default :8080).
  This checks the admin one — it's what gates the readiness of the
  admin API we use for deployment registration.
  """
  @spec health(Instance.t()) :: :ok | {:error, term()}
  def health(%Instance{admin_url: admin_url}) do
    request = Finch.build(:get, "#{admin_url}/health")

    case Finch.request(request, @finch, receive_timeout: 2_000) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Finch.Response{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def post_json(url, body) do
    encoded = Jason.encode!(body)
    headers = [{"content-type", "application/json"}, {"accept", "application/json"}]
    request = Finch.build(:post, url, headers, encoded)

    case Finch.request(request, @finch, receive_timeout: 10_000) do
      {:ok, %Finch.Response{status: status, body: body, headers: resp_headers}} ->
        {:ok, %{status: status, body: maybe_decode_json(body, resp_headers)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_decode_json(body, headers) do
    case List.keyfind(headers, "content-type", 0) do
      {_, ct} ->
        if String.contains?(ct, "json") do
          case Jason.decode(body) do
            {:ok, decoded} -> decoded
            _ -> body
          end
        else
          body
        end

      _ ->
        body
    end
  end
end
