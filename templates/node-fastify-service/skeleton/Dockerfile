# syntax=docker/dockerfile:1
# Node.js API on distroless Node.js 26 (Debian 13), non-root (uid 65532). pnpm installs from pnpm-lock.yaml
# (--frozen-lockfile fails on a stale lock); eslint and vitest gate the image; only production dependencies ship.
# Builds natively per architecture (koorikla/ci native runners). Base images pinned by multi-arch index digest.

FROM docker.io/library/node:26.13.1-trixie-slim@sha256:e6bedef217677b276c591795e169840edd9096dbf13f29df8ef8d1856b8820bc AS build
ENV CI=true PNPM_HOME=/pnpm PATH=/pnpm:$PATH
RUN npm install --global --no-fund --no-audit pnpm@12.21.0
WORKDIR /app
COPY package.json pnpm-lock.yaml ./
RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store pnpm install --frozen-lockfile
COPY eslint.config.js ./
COPY src ./src
COPY test ./test
RUN pnpm lint && pnpm test
RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store rm -rf node_modules && pnpm install --frozen-lockfile --prod

FROM gcr.io/distroless/nodejs26-debian13:nonroot@sha256:1d736cf8b5716c07a245301f92717143215d248fd55771ee1936ef4b3302e531
WORKDIR /app
COPY --from=build /app/package.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/src ./src
ARG VERSION=dev
ENV NODE_ENV=production APP_VERSION=${VERSION}
USER nonroot:nonroot
EXPOSE 8080
CMD ["src/server.js"]
