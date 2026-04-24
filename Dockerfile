FROM hexpm/elixir:1.19.5-erlang-28.4.2-debian-bookworm-20260421-slim

WORKDIR /app
ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config config
COPY apps/restate_protocol/mix.exs apps/restate_protocol/
COPY apps/restate_server/mix.exs apps/restate_server/
COPY apps/restate_example_greeter/mix.exs apps/restate_example_greeter/
RUN mix deps.get --only prod && mix deps.compile

COPY apps apps
RUN mix compile

EXPOSE 9080
CMD ["mix", "run", "--no-halt"]
