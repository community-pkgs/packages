ARG DISTRO=debian:13
FROM ${DISTRO} AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

ARG RELEASE_TAG=2.2.0
ARG ARCH=amd64

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        debhelper \
        fakeroot \
        jq && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /containerd-src

RUN curl -fSL \
        "https://github.com/containerd/containerd/releases/download/v${RELEASE_TAG}/containerd-${RELEASE_TAG}-linux-${ARCH}.tar.gz" \
        -o /tmp/containerd.tar.gz && \
    mkdir -p binaries && \
    tar xz --strip-components=1 -C binaries -f /tmp/containerd.tar.gz && \
    rm /tmp/containerd.tar.gz

COPY packages/containerd/debian/  debian/
COPY scripts/gen-changelog-github.sh /usr/local/bin/gen-changelog-github.sh
RUN chmod +x /usr/local/bin/gen-changelog-github.sh

RUN --mount=type=secret,id=github_token \
    GITHUB_TOKEN="$(cat /run/secrets/github_token 2>/dev/null || true)" \
    gen-changelog-github.sh containerd containerd/containerd "${RELEASE_TAG}" \
        "community-pkgs <https://github.com/community-pkgs/packages>" stable

ENV DEB_BUILD_OPTIONS="parallel=$(nproc)"
RUN sed -i "s/^Architecture: any$/Architecture: ${ARCH}/" debian/control && \
    dpkg-buildpackage -b -us -uc --host-arch ${ARCH}

FROM scratch AS output
COPY --from=builder /*.deb /
