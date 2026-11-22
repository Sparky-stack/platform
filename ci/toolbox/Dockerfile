# syntax=docker/dockerfile:1
# ghcr.io/koorikla/platform/ci-toolbox: the tools ci/scripts need, so in-cluster builds
# (OpenChoreo ClusterWorkflows, addons/openchoreo-workflow-plane) run the exact
# same scripts as GitHub Actions. Multi-arch (linux/amd64, linux/arm64).
#
#   docker run --rm -e IMAGE_REF=... ghcr.io/koorikla/platform/ci-toolbox@sha256:<digest> \
#     scan-image.sh            # scripts/common/*.sh are on PATH
#
# Tool versions: Renovate bumps every ARG below from its "# renovate:" annotation
# (renovate.json). TRIVY_VERSION moves with setup-trivy's version: in .github/workflows/app-*.yaml
# (ci/tests/tool-pins.test.sh keeps them equal).
ARG BASE_IMAGE=docker.io/library/debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2

FROM ${BASE_IMAGE} AS fetch
ARG TARGETARCH
# renovate: datasource=github-releases depName=aquasecurity/trivy
ARG TRIVY_VERSION=0.76.2
# renovate: datasource=github-releases depName=anchore/syft
ARG SYFT_VERSION=1.57.1
# renovate: datasource=github-releases depName=sigstore/cosign
ARG COSIGN_VERSION=3.1.4
# renovate: datasource=github-releases depName=google/go-containerregistry
ARG CRANE_VERSION=0.22.1
# renovate: datasource=github-releases depName=helm/helm
ARG HELM_VERSION=4.3.2
# renovate: datasource=github-releases depName=mikefarah/yq
ARG YQ_VERSION=4.54.3
# renovate: datasource=github-releases depName=crossplane/crossplane
ARG CROSSPLANE_VERSION=2.5.0
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /dl
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
RUN case "${TARGETARCH}" in \
      amd64) T=64bit; X=x86_64 ;; \
      arm64) T=ARM64; X=arm64 ;; \
      *) echo "unsupported ${TARGETARCH}"; exit 1 ;; \
    esac; \
    gh=https://github.com; mkdir -p /out; \
    # trivy
    f="trivy_${TRIVY_VERSION}_Linux-${T}.tar.gz"; \
    curl -fsSLO "${gh}/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/${f}"; \
    curl -fsSL "${gh}/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_checksums.txt" | grep " ${f}\$" | sha256sum -c -; \
    tar -xzf "${f}" -C /out trivy; \
    # syft
    f="syft_${SYFT_VERSION}_linux_${TARGETARCH}.tar.gz"; \
    curl -fsSLO "${gh}/anchore/syft/releases/download/v${SYFT_VERSION}/${f}"; \
    curl -fsSL "${gh}/anchore/syft/releases/download/v${SYFT_VERSION}/syft_${SYFT_VERSION}_checksums.txt" | grep " ${f}\$" | sha256sum -c -; \
    tar -xzf "${f}" -C /out syft; \
    # cosign
    f="cosign-linux-${TARGETARCH}"; \
    curl -fsSLO "${gh}/sigstore/cosign/releases/download/v${COSIGN_VERSION}/${f}"; \
    curl -fsSL "${gh}/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign_checksums.txt" | grep " ${f}\$" | sha256sum -c -; \
    install -m 0755 "${f}" /out/cosign; \
    # crane
    f="go-containerregistry_Linux_${X}.tar.gz"; \
    curl -fsSLO "${gh}/google/go-containerregistry/releases/download/v${CRANE_VERSION}/${f}"; \
    curl -fsSL "${gh}/google/go-containerregistry/releases/download/v${CRANE_VERSION}/checksums.txt" | grep " ${f}\$" | sha256sum -c -; \
    tar -xzf "${f}" -C /out crane; \
    # helm
    f="helm-v${HELM_VERSION}-linux-${TARGETARCH}.tar.gz"; \
    curl -fsSLO "https://get.helm.sh/${f}"; \
    echo "$(curl -fsSL "https://get.helm.sh/${f}.sha256sum" | cut -d' ' -f1)  ${f}" | sha256sum -c -; \
    tar -xzf "${f}" --strip-components=1 -C /out "linux-${TARGETARCH}/helm"; \
    # yq (pinned over https; upstream checksum format is multi-hash)
    curl -fsSL -o /out/yq "${gh}/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${TARGETARCH}"; \
    # crossplane CLI
    curl -fsSL -o /out/crossplane "https://cli.crossplane.io/stable/v${CROSSPLANE_VERSION}/bin/linux_${TARGETARCH}/crossplane"; \
    echo "$(curl -fsSL "https://cli.crossplane.io/stable/v${CROSSPLANE_VERSION}/bin/linux_${TARGETARCH}/crossplane.sha256" | cut -d' ' -f1)  /out/crossplane" | sha256sum -c -; \
    chmod 0755 /out/*

FROM ${BASE_IMAGE}
RUN apt-get update \
 && apt-get install -y --no-install-recommends bash ca-certificates curl git jq make diffutils \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --uid 65532 --create-home --home-dir /home/ci --shell /bin/bash ci
COPY --from=fetch /out/ /usr/local/bin/
COPY scripts/ /opt/koorikla-ci/scripts/
COPY toolbox/smoke.sh /usr/local/bin/toolbox-smoke
ARG VERSION=dev
ENV KOORIKLA_CI_VERSION=${VERSION} \
    CI_SCRIPTS=/opt/koorikla-ci/scripts \
    PATH=/opt/koorikla-ci/scripts/common:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
USER 65532:65532
WORKDIR /workspace
CMD ["bash"]
