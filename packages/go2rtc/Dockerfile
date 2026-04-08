ARG DISTRO=debian:13
FROM ${DISTRO} AS builder

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC

ARG RELEASE_TAG=1.9.14
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

WORKDIR /go2rtc-src

RUN mkdir -p binaries && \
    curl -fSL \
        "https://github.com/AlexxIT/go2rtc/releases/download/v${RELEASE_TAG}/go2rtc_linux_${ARCH}" \
        -o binaries/go2rtc && \
    chmod +x binaries/go2rtc

COPY packages/go2rtc/debian/ debian/
COPY --chmod=0755 scripts/gen-changelog-github.sh /usr/local/bin/gen-changelog-github.sh

RUN --mount=type=secret,id=github_token \
    GITHUB_TOKEN="$(cat /run/secrets/github_token 2>/dev/null || true)" \
    gen-changelog-github.sh go2rtc AlexxIT/go2rtc "${RELEASE_TAG}" \
        "community-pkgs <https://github.com/community-pkgs/packages>" stable

RUN chmod +x debian/rules && \
    sed -i "s/^Architecture: any$/Architecture: ${ARCH}/" debian/control && \
    DEB_BUILD_OPTIONS="parallel=$(nproc)" dpkg-buildpackage -b -us -uc --host-arch ${ARCH}

FROM scratch AS output
COPY --from=builder /*.deb /
