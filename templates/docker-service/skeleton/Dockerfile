# syntax=docker/dockerfile:1
# Bring your own Dockerfile: replace everything below with your build. The golden-path contract the platform relies on:
#   - multi-arch (linux/amd64 + linux/arm64), base images fully qualified and pinned by index digest (Renovate);
#   - a non-root user, ideally a distroless or Chainguard runtime image;
#   - an HTTP server on port 8080 with GET /healthz (deploy/openchoreo/workload.yaml).
# This placeholder serves www/ with busybox httpd (a static binary) on distroless static, non-root (uid 65532).

FROM docker.io/library/busybox:1.38.0-musl@sha256:80e38f9a1b39188b8bdb28879178edb322a4402b081a9aedda1924609decd6f6 AS busybox

FROM gcr.io/distroless/static-debian13:nonroot@sha256:aafe993665bf6200db38a02c11a9351e782a84b6a45e7f33b6695638c88e3931
COPY --from=busybox /bin/busybox /busybox
COPY www/ /www/
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/busybox", "httpd", "-f", "-v", "-p", "8080", "-h", "/www"]
