# Credo's test helpers (`to_source_file/1`, `run_check/2`) call into
# `Credo.Service.SourceFileAST`, a GenServer started by Credo's OTP
# application. Because we declare `:credo` with `runtime: false` in
# mix.exs, the application isn't started automatically — start it
# here so the `Restate.Credo.Checks.*` tests have working services.
{:ok, _} = Application.ensure_all_started(:credo)

ExUnit.start()
