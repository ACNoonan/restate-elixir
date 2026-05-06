import Config

# Bind Bandit to an OS-assigned ephemeral port during `mix test` so
# the suite doesn't fight whatever's already running on 9080
# (typical when a Restate dev container or another SDK is up).
# Endpoint tests drive `Plug.Test.conn |> Endpoint.call/2` directly
# and don't need a real listener; the app still boots so the
# Registry / DrainCoordinator are available as expected.
config :restate_server, port: 0
