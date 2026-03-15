ARG DISTRO=debian:13
FROM ${DISTRO} AS builder

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC

# Version format: 007.XXYY.0000.0000
# URL format: https://docs.broadcom.com/docs-and-downloads/007.XXYY.0000.0000_MR%207.XX_Storcli.zip
ARG RELEASE_TAG=007.3603.0000.0000
ARG RELEASE_URL=https://docs.broadcom.com/docs-and-downloads/007.3603.0000.0000_MR%207.36_Storcli.zip
ARG ARCH=amd64

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        debhelper \
        fakeroot \
        unzip && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /storcli-src

RUN curl -fSL "${RELEASE_URL}" -o outer.zip && \
    unzip -q outer.zip && \
    rm outer.zip && \
    unzip -q storcli_rel/Unified_storcli_all_os.zip && \
    rm -rf storcli_rel

RUN mkdir -p binaries && \
    if [ "${ARCH}" = "arm64" ]; then \
        _deb=$(find Unified_storcli_all_os/ARM/Linux -name "*.deb" | head -1); \
    else \
        _deb=$(find Unified_storcli_all_os/Ubuntu -name "*.deb" | head -1); \
    fi && \
    mkdir -p _deb_extract && \
    ar x "$_deb" --output=_deb_extract && \
    tar -xJf _deb_extract/data.tar.xz --strip-components=4 -C binaries ./opt/MegaRAID/storcli/storcli64 && \
    rm -rf _deb_extract Unified_storcli_all_os && \
    chmod +x binaries/storcli64

COPY packages/storcli/debian/ debian/

RUN DEB_VERSION="$(echo "${RELEASE_TAG}" | sed 's/^0*//')" && \
    printf '%s (%s-1~stable) stable; urgency=medium\n\n  * Upstream release %s.\n\n -- community-pkgs <https://github.com/community-pkgs/packages>  %s\n' \
        "storcli" "${DEB_VERSION}" "${RELEASE_TAG}" "$(date -R)" > debian/changelog

RUN chmod +x debian/rules && \
    sed -i "s/^Architecture: any$/Architecture: ${ARCH}/" debian/control && \
    DEB_BUILD_OPTIONS="parallel=$(nproc)" dpkg-buildpackage -b -us -uc --host-arch ${ARCH}

FROM scratch AS output
COPY --from=builder /*.deb /
