# --- Build stage --------------------------------------------------------
FROM hexpm/elixir:1.19.5-erlang-28.4.2-debian-bookworm-20260421-slim AS build

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
RUN mix release

# --- Runtime stage ------------------------------------------------------
FROM debian:bookworm-20260421-slim AS runtime

# OpenSSL + ncurses are runtime deps of the Erlang VM; locales avoids the
# noisy LANG warnings on boot. Nothing else is needed.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libssl3 libncurses6 ca-certificates locales \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen \
    && locale-gen

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
COPY --from=build /app/_build/prod/rel/restate_elixir ./

EXPOSE 9080
ENV PORT=9080

CMD ["/app/bin/restate_elixir", "start"]
