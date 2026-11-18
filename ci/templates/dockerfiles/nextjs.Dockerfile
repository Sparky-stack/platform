# syntax=docker/dockerfile:1
# Next.js standalone image (requires `output: "standalone"` in next.config.*).
# Builds on the target platform (native runner or QEMU) because node_modules
# may contain platform-specific binaries (sharp, swc, ...).
ARG NODE_IMAGE=docker.io/library/node:24-trixie-slim@sha256:af02d57b57719b9657a45199a79264a9437940cd55b3c7b3fc99615654f124a0

FROM ${NODE_IMAGE} AS deps
WORKDIR /app
COPY package.json package-lock.json* pnpm-lock.yaml* yarn.lock* .npmrc* ./
RUN --mount=type=cache,target=/root/.npm \
    --mount=type=cache,target=/root/.local/share/pnpm/store \
    if [ -f pnpm-lock.yaml ]; then corepack enable pnpm && pnpm install --frozen-lockfile; \
    elif [ -f yarn.lock ]; then corepack enable yarn && yarn install --immutable 2>/dev/null || yarn install --frozen-lockfile; \
    else npm ci --no-audit --no-fund; fi

FROM ${NODE_IMAGE} AS build
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1
COPY --from=deps /app/node_modules ./node_modules
COPY . .
ARG VERSION=dev
ENV NEXT_PUBLIC_VERSION=${VERSION}
RUN if [ -f pnpm-lock.yaml ]; then corepack enable pnpm && pnpm run build; \
    elif [ -f yarn.lock ]; then corepack enable yarn && yarn run build; \
    else npm run build; fi

# Runtime: distroless Node.js, non-root (uid 65532), no shell or package manager.
FROM gcr.io/distroless/nodejs24-debian13:nonroot@sha256:6abfcb367ebc291572c774c1592a986be2ab26a2486f73093401327495a5962a
WORKDIR /app
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 PORT=3000 HOSTNAME=0.0.0.0
COPY --from=build --chown=nonroot:nonroot /app/public ./public
COPY --from=build --chown=nonroot:nonroot /app/.next/standalone ./
COPY --from=build --chown=nonroot:nonroot /app/.next/static ./.next/static
USER nonroot:nonroot
EXPOSE 3000
CMD ["server.js"]
