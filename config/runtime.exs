import Config

if config_env() == :prod do
  port = System.get_env("PORT", "9080") |> String.to_integer()
  config :restate_server, port: port
end
