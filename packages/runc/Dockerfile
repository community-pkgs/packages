ARG DISTRO=debian:13
FROM ${DISTRO} AS builder

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC

ARG RELEASE_TAG=1.4.0
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

WORKDIR /runc-src

RUN mkdir -p binaries && \
    curl -fSL \
        "https://github.com/opencontainers/runc/releases/download/v${RELEASE_TAG}/runc.${ARCH}" \
        -o binaries/runc && \
    chmod +x binaries/runc

COPY packages/runc/debian/ debian/
COPY --chmod=0755 scripts/gen-changelog-github.sh /usr/local/bin/gen-changelog-github.sh

RUN --mount=type=secret,id=github_token \
    GITHUB_TOKEN="$(cat /run/secrets/github_token 2>/dev/null || true)" \
    gen-changelog-github.sh runc opencontainers/runc "${RELEASE_TAG}" \
        "community-pkgs <https://github.com/community-pkgs/packages>" stable

RUN chmod +x debian/rules && \
    sed -i "s/^Architecture: any$/Architecture: ${ARCH}/" debian/control && \
    DEB_BUILD_OPTIONS="parallel=$(nproc)" dpkg-buildpackage -b -us -uc --host-arch ${ARCH}

FROM scratch AS output
COPY --from=builder /*.deb /
