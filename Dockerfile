# ── Build stage ───────────────────────────────────────────────────────────
FROM elixir:1.17-otp-27-slim AS build

ENV MIX_ENV=prod

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git \
    && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

# Deps first for layer caching
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod
RUN mix deps.compile

# App sources + assets
COPY priv priv
COPY lib lib
COPY assets assets

RUN mix assets.deploy
RUN mix compile
RUN mix phx.gen.release
RUN mix release

# ── Runtime stage ─────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS app

RUN apt-get update && apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 MIX_ENV=prod

WORKDIR /app

RUN useradd --create-home appuser
USER appuser

COPY --from=build --chown=appuser:appuser /app/_build/prod/rel/mlb_fan ./

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS http://localhost:4000/health || exit 1

# Migrate then boot the server.
CMD ["/bin/sh", "-c", "bin/mlb_fan eval 'MlbFan.Release.migrate()' && bin/mlb_fan start"]
