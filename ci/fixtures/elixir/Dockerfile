# syntax=docker/dockerfile:1
# Elixir/Phoenix release image: build with the official Elixir image, run the
# self-contained release (ERTS included) on debian trixie-slim as non-root.
# The build runs on the target platform (native runner or QEMU): a release
# embeds ERTS and NIFs for the architecture it was built on.
# Set APP_NAME to the release name (mix.exs `releases:` key / app name).
ARG BUILDER_IMAGE=docker.io/library/elixir:1.20.5-otp-29@sha256:1b850191faeaae55678b782cd8b34d391f793672f3175b1956d024f794ca321b
ARG RUNNER_IMAGE=docker.io/library/debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2

FROM ${BUILDER_IMAGE} AS build
ENV MIX_ENV=prod
WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
RUN --mount=type=cache,target=/root/.hex/packages \
    mix deps.get --only prod && mix deps.compile
COPY config* ./config/
COPY lib ./lib
COPY priv* ./priv/
# Phoenix: uncomment to build assets.
# COPY assets ./assets
# RUN mix assets.deploy
ARG VERSION=dev
RUN mix compile && mix release --overwrite

FROM ${RUNNER_IMAGE}
ARG APP_NAME=ci_selftest
RUN apt-get update \
 && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen \
 && useradd --system --uid 65532 --home /app --shell /usr/sbin/nologin app
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8 MIX_ENV=prod
WORKDIR /app
COPY --from=build --chown=65532:65532 /app/_build/prod/rel/${APP_NAME} ./
RUN ln -s /app/bin/${APP_NAME} /app/bin/server
USER 65532:65532
EXPOSE 4000
CMD ["/app/bin/server", "start"]
