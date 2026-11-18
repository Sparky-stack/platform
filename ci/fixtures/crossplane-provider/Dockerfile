# syntax=docker/dockerfile:1
# Provider controller image: cross-compiled on $BUILDPLATFORM, distroless static.
FROM --platform=$BUILDPLATFORM docker.io/library/golang:1.27.4-alpine@sha256:0a5f7fe796599ff487605987432e7619ae45beeb2fba4c2ce0b907879932aebf AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
ARG VERSION=dev
ARG TARGETOS
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath \
    -ldflags="-s -w -X github.com/koorikla/ci/fixtures/crossplane-provider/internal/version.Version=${VERSION}" \
    -o /out/provider ./cmd/provider

FROM gcr.io/distroless/static-debian13:nonroot@sha256:aafe993665bf6200db38a02c11a9351e782a84b6a45e7f33b6695638c88e3931
COPY --from=build /out/provider /usr/local/bin/crossplane-provider
USER 65532:65532
ENTRYPOINT ["crossplane-provider"]
