# syntax=docker/dockerfile:1
# Python service on distroless python3 (Debian 13, Python 3.13), non-root (uid 65532). The build stage is the same
# distroless image's :debug variant (busybox shell), so the virtualenv links the exact interpreter the runtime ships.
# uv installs from uv.lock (--locked fails on a stale lock); ruff and pytest gate the image. Builds natively per
# architecture (app-* workflows on native runners). Base images pinned by multi-arch index digest (Renovate).

FROM ghcr.io/astral-sh/uv:0.13.8@sha256:5cc1805e2426484abca4ad46ea783bab281fdb225fd82d8ce6d66a81254bac85 AS uv

FROM gcr.io/distroless/python3-debian13:debug@sha256:262eeb1f296981b95af82c62fda0973d62585510ddb6af1eda80f4dfd3e492d5 AS build
SHELL ["/busybox/sh", "-c"]
COPY --from=uv /uv /usr/local/bin/uv
ENV UV_PYTHON=/usr/bin/python3 \
    UV_PYTHON_DOWNLOADS=never \
    UV_PROJECT_ENVIRONMENT=/app/.venv \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1
WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv uv sync --locked
COPY app ./app
COPY tests ./tests
RUN uv run --locked --offline ruff check . \
 && uv run --locked --offline ruff format --check . \
 && uv run --locked --offline pytest -q -p no:cacheprovider
# runtime dependencies only
RUN --mount=type=cache,target=/root/.cache/uv uv sync --locked --no-dev

FROM gcr.io/distroless/python3-debian13:nonroot@sha256:6c4cb3bfa4b555429dd19541796a6ba6b30c84675b460bd0bd5072f7d5bdae71
WORKDIR /app
COPY --from=build /app/.venv /app/.venv
COPY app ./app
ARG VERSION=dev
ENV APP_VERSION=${VERSION} \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/app/.venv/bin/python", "-m", "app"]
