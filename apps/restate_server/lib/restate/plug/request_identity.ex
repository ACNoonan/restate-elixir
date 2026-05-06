defmodule Restate.Plug.RequestIdentity do
  @moduledoc """
  Plug that enforces `Restate.RequestIdentity` verification on
  configured paths.

  Reads `:request_identity_keys` from the `:restate_server` app
  environment at first request and caches the parsed verifier in
  `:persistent_term`. Without that config the plug is a no-op —
  useful in dev / docker-compose loops where signing is off.

  Path filter defaults to `["/invoke/"]` so `GET /discover` stays
  unsigned (Restate's runtime queries discovery without signing).

  ## Wiring

  Already installed in `Restate.Server.Endpoint`. To install
  yourself:

      plug Restate.Plug.RequestIdentity, paths: ["/invoke/"]

  ## Configuration

      # config/runtime.exs
      if keys = System.get_env("RESTATE_REQUEST_IDENTITY_KEYS") do
        config :restate_server,
          request_identity_keys: String.split(keys, ",", trim: true)
      end

  ## Reload

  The verifier is built once per app boot. Restart the BEAM to pick
  up new keys. (Multiple keys are supported for rolling rotation
  without downtime — list both old and new keys during the cutover.)
  """

  @behaviour Plug

  alias Restate.RequestIdentity

  @cache_key {__MODULE__, :verifier}
  @config_app :restate_server
  @config_key :request_identity_keys

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    case verifier() do
      nil ->
        conn

      %RequestIdentity{} = verifier ->
        paths = Keyword.get(opts, :paths, ["/invoke/"])

        if matches_path?(conn, paths) do
          enforce(conn, verifier)
        else
          conn
        end
    end
  end

  defp verifier do
    case :persistent_term.get(@cache_key, :unset) do
      :unset ->
        v = build_verifier()
        :persistent_term.put(@cache_key, v)
        v

      cached ->
        cached
    end
  end

  defp build_verifier do
    case Application.get_env(@config_app, @config_key) do
      nil -> nil
      [] -> nil
      keys when is_list(keys) -> RequestIdentity.from_keys(keys)
    end
  end

  defp matches_path?(conn, paths) do
    Enum.any?(paths, &String.starts_with?(conn.request_path, &1))
  end

  defp enforce(conn, verifier) do
    case RequestIdentity.verify_request(verifier, conn.req_headers) do
      :ok ->
        conn

      {:error, _reason} ->
        conn
        |> Plug.Conn.send_resp(401, "")
        |> Plug.Conn.halt()
    end
  end

  @doc """
  Test helper: drop the cached verifier so the next request re-reads
  config. Not part of the production surface.
  """
  @spec reset_cache() :: :ok
  def reset_cache do
    :persistent_term.erase(@cache_key)
    :ok
  end
end
