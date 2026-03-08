# Stage 1: Builder
ARG DISTRO=debian:13
FROM ${DISTRO} AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

ARG RELEASE_TAG=9.0.3
ARG MAJOR=9
ARG ARCH=amd64
ARG CODENAME

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        pkg-config \
        libssl-dev \
        libsystemd-dev \
        zlib1g-dev \
        debhelper \
        libhiredis-dev \
        libjemalloc-dev \
        librdmacm-dev \
        libibverbs-dev \
        rdma-core \
        fakeroot \
        jq \
        liblua5.1-0-dev \
        liblzf-dev \
        lua-bitop-dev \
        lua-cjson-dev \
        procps \
        tcl \
        tcl-tls && \
    if [ "$(dpkg --print-architecture)" = "arm64" ]; then \
        apt-get install -y --no-install-recommends libatomic1; \
    fi && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /valkey-src

RUN curl -fSL \
        "https://github.com/valkey-io/valkey/archive/refs/tags/${RELEASE_TAG}.tar.gz" \
        -o /tmp/valkey.tar.gz \
    && tar xz --strip-components=1 -f /tmp/valkey.tar.gz \
    && rm /tmp/valkey.tar.gz \
    && make distclean

COPY packages/valkey/debian/  debian/
COPY scripts/gen-changelog-github.sh /usr/local/bin/gen-changelog-github.sh
RUN chmod +x /usr/local/bin/gen-changelog-github.sh

# GITHUB_TOKEN is injected via BuildKit secret so it never appears in image
# layers or `docker history` output.
RUN --mount=type=secret,id=github_token \
    GITHUB_TOKEN="$(cat /run/secrets/github_token 2>/dev/null || true)" \
    gen-changelog-github.sh valkey valkey-io/valkey "${RELEASE_TAG}" \
        "community-pkgs <https://github.com/community-pkgs/packages>" "${CODENAME}"

ENV MAJOR=${MAJOR}
ENV DEB_BUILD_OPTIONS="parallel=$(nproc)"
RUN dpkg-buildpackage -b -us -uc --host-arch ${ARCH}

# Stage 2: Output
FROM scratch AS output
COPY --from=builder /*.deb /
