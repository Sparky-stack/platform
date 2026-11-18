# syntax=docker/dockerfile:1
# Rust service as a static (musl) binary on distroless static, non-root (uid 65532). rustfmt, clippy and the unit tests
# gate the image; Cargo.lock is enforced (--locked). Builds natively per architecture (app-* workflows on native runners).
# Base images pinned by multi-arch index digest (Renovate).

FROM docker.io/library/rust:1.100.0-alpine3.24@sha256:de1e0058543a81ed7b046629167db587c67a94bdf37cce14eb27f0ec83baaffb AS build
# rustfmt and clippy are not in the image; the components match the pinned toolchain.
RUN rustup component add rustfmt clippy
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY src ./src
ARG VERSION=dev
RUN --mount=type=cache,target=/usr/local/cargo/registry --mount=type=cache,target=/src/target \
    cargo fmt --check \
 && cargo clippy --locked --all-targets -- -D warnings \
 && cargo test --locked \
 && APP_VERSION="${VERSION}" cargo build --locked --release \
 && mkdir -p /out && cp target/release/app /out/app

FROM gcr.io/distroless/static-debian13:nonroot@sha256:aafe993665bf6200db38a02c11a9351e782a84b6a45e7f33b6695638c88e3931
COPY --from=build /out/app /app
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/app"]
