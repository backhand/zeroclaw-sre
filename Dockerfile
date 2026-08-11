# zeroclaw-k3s-sre — a ZeroClaw distribution for k3s cluster operations.
#
# Base image note: the spec named `zeroclawlabs/zeroclaw:latest` on Docker Hub.
# That repository does not exist; official images are published to
# `ghcr.io/zeroclaw-labs/zeroclaw`, and the `latest` tag there is distroless —
# no shell, no package manager, so no entrypoint script and no kubectl. The
# `debian` tag carries the same binary on debian-slim and is the only variant
# this distribution can extend. See NOTES.md §1.
#
#   docker buildx build --platform linux/amd64,linux/arm64 -t <ref> .

# Set ZC_SLACK=1 to build ZeroClaw from source with the Slack channel compiled
# in. Declared here because it is interpolated into a FROM line below, which
# puts it in the global (pre-stage) ARG scope.
ARG ZC_SLACK=0

# ── Stage 0: the Alertmanager adapter ────────────────────────────
FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS adapter
ARG TARGETARCH
WORKDIR /src
COPY alert-adapter/go.mod ./
COPY alert-adapter/*.go ./
RUN go vet ./... && go test ./...
RUN CGO_ENABLED=0 GOOS=linux GOARCH="${TARGETARCH}" \
    go build -trimpath -ldflags='-s -w' -o /out/alert-adapter .

# ── Stage 1: pinned CLI tooling ──────────────────────────────────
FROM debian:trixie-slim AS tools
ARG TARGETARCH
# kubectl minor must stay within one minor of the k3s API server (Kubernetes
# version-skew policy). v1.36.x matches k3s v1.36.x, the current stable line.
ARG KUBECTL_VERSION=v1.36.3
ARG GH_VERSION=2.97.0
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    rm -rf /var/lib/apt/lists/*; \
    \
    curl -fsSLo /tmp/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl"; \
    curl -fsSLo /tmp/kubectl.sha256 \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl.sha256"; \
    echo "$(cat /tmp/kubectl.sha256)  /tmp/kubectl" | sha256sum -c -; \
    install -m 0755 /tmp/kubectl /out/kubectl 2>/dev/null || { mkdir -p /out && install -m 0755 /tmp/kubectl /out/kubectl; }; \
    \
    curl -fsSLo /tmp/gh.tgz \
      "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${TARGETARCH}.tar.gz"; \
    tar -xzf /tmp/gh.tgz -C /tmp; \
    install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${TARGETARCH}/bin/gh" /out/gh; \
    \
    /out/kubectl version --client=true; \
    /out/gh --version

# ── Stage 1b: ZeroClaw from source (opt-in) ──────────────────────
# NEEDED FOR SLACK. No published ZeroClaw image compiles the Slack channel —
# `zeroclaw channel list` in both `:latest` and `:debian` reports
# "🚫 Slack (configured, not compiled)". Discord, webhook and CLI are in;
# Slack is not. See NOTES.md §14.
#
# This stage is skipped entirely unless you ask for it, because it is a full
# Rust build (~2 GB RAM, tens of minutes) against a ~10s image pull:
#
#   docker build --build-arg ZC_SLACK=1 .
#
# BuildKit only builds the stage that `zcbin` actually resolves to, so with
# ZC_SLACK=0 (the default) nothing below is compiled at all.
#
# ZC_FEATURES adds to the crate's default feature set rather than replacing it.
# Two pins that both matter:
#   1.96 — 0.8.4 declares rust-version = 1.96.1, and an older toolchain fails
#          resolution before compiling anything.
#   bookworm — the published runtime image is Debian 12 (glibc 2.36) even
#          though upstream's own Dockerfile says trixie. Building on trixie
#          (glibc 2.41) produces a binary that dies at startup with
#          "GLIBC_2.39 not found". The builder must match the runtime's libc.
FROM rust:1.96-slim-bookworm AS zcsource
ARG ZC_VERSION=v0.8.4
ARG ZC_FEATURES=channel-slack
RUN apt-get update \
 && apt-get install -y --no-install-recommends pkg-config git ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone --depth 1 --branch "${ZC_VERSION}" \
      https://github.com/zeroclaw-labs/zeroclaw.git . \
 && cargo build --release --locked --features "${ZC_FEATURES}" \
 && install -D -m 0755 target/release/zeroclaw /usr/local/bin/zeroclaw \
 && zeroclaw --version

# ── Stage 1c: pick which zeroclaw binary the runtime gets ────────
# `zcbin-0` is the published binary, `zcbin-1` the source build. The runtime
# copies from `zcbin`, which resolves to one or the other — the unselected
# stage is never built.
FROM ghcr.io/zeroclaw-labs/zeroclaw:debian@sha256:d2b3ac2e6b6dd3b0d977b3722fea8bc5ba414c2d5c34d48fe42838aac217afa5 AS zcbin-0
FROM zcsource AS zcbin-1
FROM zcbin-${ZC_SLACK} AS zcbin

# ── Stage 2: runtime ─────────────────────────────────────────────
FROM ghcr.io/zeroclaw-labs/zeroclaw:debian@sha256:d2b3ac2e6b6dd3b0d977b3722fea8bc5ba414c2d5c34d48fe42838aac217afa5 AS runtime

USER root

# gettext-base = envsubst (config rendering); jq = the skill's playbook.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        gettext-base \
        jq \
        tini; \
    rm -rf /var/lib/apt/lists/*

# Either the published binary or the source build, per ZC_SLACK.
COPY --from=zcbin /usr/local/bin/zeroclaw /usr/local/bin/zeroclaw

# Smoke-test the binary in the runtime image, not just in the builder. A libc
# or linker mismatch between the two otherwise surfaces as a crash-looping pod
# rather than a failed build.
RUN zeroclaw --version

COPY --from=tools    /out/kubectl       /usr/local/bin/kubectl
COPY --from=tools    /out/gh            /usr/local/bin/gh
COPY --from=adapter  /out/alert-adapter /usr/local/bin/alert-adapter

# The distro payload. /opt/distro is read-only at runtime; entrypoint.sh copies
# skills/ and sops/ from here into the live workspace on every boot, which makes
# an image tag bump the upgrade path for agent behaviour (spec §6.3).
COPY config/config.toml.tmpl  /opt/distro/config/config.toml.tmpl
COPY workspace/               /opt/distro/workspace/
COPY entrypoint.sh            /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh \
             /usr/local/bin/alert-adapter \
             /usr/local/bin/kubectl \
             /usr/local/bin/gh \
 && chmod -R a+rX /opt/distro

# Mount points, pre-created and owned by the runtime user so the container also
# works without mounts (CI self-test) and so an emptyDir/PVC inherits a sane
# owner alongside the pod's fsGroup.
RUN mkdir -p /data /tmp \
 && chown 65534:65534 /data \
 && chmod 1777 /tmp \
 # The base image's own state directory is unused here — this distribution puts
 # everything under /data. Remove it so no writable path outside /data and /tmp
 # survives in the image (`make image-scan` enforces this).
 && rm -rf /zeroclaw-data \
 # World-writable system dirs are moot under readOnlyRootFilesystem, but the
 # image should not depend on that to be sound.
 && chmod 0755 /var/tmp /run/lock 2>/dev/null || true

# Writable state lives only on mounts: /data (PVC) and /tmp (emptyDir).
# The image itself carries no writable state path, so the pod can run with
# readOnlyRootFilesystem: true.
ENV ZEROCLAW_CONFIG_DIR=/data \
    DISTRO_DIR=/opt/distro \
    HOME=/data \
    LANG=C.UTF-8 \
    ALERT_ADAPTER_PORT=9099

# 65534 (nobody) matches the base image and deploy/deployment.yaml.
USER 65534:65534
WORKDIR /data
EXPOSE 42617 9099

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["/usr/local/bin/kubectl", "version", "--client=true"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
