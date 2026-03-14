ARG DISTRO=debian:13
FROM ${DISTRO} AS builder

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC

ARG RELEASE_TAG=3.5.21
ARG ARCH=amd64

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        debhelper \
        fakeroot \
        jq && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /etcd-src

RUN GOARCH="$([ "${ARCH}" = "arm64" ] && echo "arm64" || echo "amd64")" && \
    curl -fSL \
        "https://github.com/etcd-io/etcd/releases/download/v${RELEASE_TAG}/etcd-v${RELEASE_TAG}-linux-${GOARCH}.tar.gz" \
        -o /tmp/etcd.tar.gz && \
    mkdir -p binaries && \
    tar xz --strip-components=1 -C binaries -f /tmp/etcd.tar.gz && \
    rm /tmp/etcd.tar.gz && \
    curl -fSL \
        "https://raw.githubusercontent.com/etcd-io/etcd/v${RELEASE_TAG}/etcd.conf.yml.sample" \
        -o binaries/etcd.conf.yml.sample

COPY packages/etcd/debian/ debian/
COPY --chmod=0755 scripts/gen-changelog-md.sh /usr/local/bin/gen-changelog-md.sh

RUN --mount=type=secret,id=github_token \
    GITHUB_TOKEN="$(cat /run/secrets/github_token 2>/dev/null || true)" \
    gen-changelog-md.sh etcd etcd-io/etcd "${RELEASE_TAG}" \
        "community-pkgs <https://github.com/community-pkgs/packages>" stable

RUN chmod +x debian/rules && \
    sed -i "s/^Architecture: any$/Architecture: ${ARCH}/" debian/control && \
    DEB_BUILD_OPTIONS="parallel=$(nproc)" dpkg-buildpackage -b -us -uc --host-arch ${ARCH}

FROM scratch AS output
COPY --from=builder /*.deb /
