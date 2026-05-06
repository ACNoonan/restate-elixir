import Config

# Per-env overrides. Currently only `config/test.exs` exists (binds
# Bandit to an ephemeral port so `mix test` doesn't collide with a
# running dev server on 9080). `runtime.exs` handles prod.
if File.exists?(Path.join(__DIR__, "#{config_env()}.exs")) do
  import_config "#{config_env()}.exs"
end
