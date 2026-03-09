#!/usr/bin/env bash
# assemble-apt-repo.sh
#
# Assemble a signed APT repository from downloaded .deb artifacts.
#
# Uses dpkg-scanpackages --multiversion to generate Packages files that include
# ALL versions of each package, so users can install any specific version with:
#   apt install valkey-server=7.2.11-1~noble
#
# Pool layout:
#   <REPO_DIR>/pool/<component>/v/<project_slug>/<package>_<version>_<arch>.deb
#
# Dist layout:
#   <REPO_DIR>/dists/<suite>/<component>/binary-<arch>/Packages
#   <REPO_DIR>/dists/<suite>/<component>/binary-<arch>/Packages.gz
#   <REPO_DIR>/dists/<suite>/<component>/binary-<arch>/Packages.xz
#   <REPO_DIR>/dists/<suite>/Release
#   <REPO_DIR>/dists/<suite>/Release.gpg
#   <REPO_DIR>/dists/<suite>/InRelease
#
# Required environment variables:
#   REPO_DIR            Repository root directory (e.g. repo)
#   ARTIFACTS_DIR       Directory containing downloaded artifact subdirectories
#   REPO_CODENAME       Suite/Codename to publish into (e.g. valkey9)
#   REPO_ORIGIN         Origin field in Release
#   REPO_LABEL          Label field in Release
#   REPO_DESCRIPTION    Description field in Release
#   GPG_KEY_ID          GPG key ID used for signing
#
# Optional environment variables:
#   REPO_SUITE          Suite field in Release (default: stable)
#   ARTIFACT_NAME_PREFIX  Prefix for artifact dirs (default: packages)
#   RELEASE_TAG_FILTER    When set, only process artifact dirs whose name
#                         contains this tag after the prefix, and strip it
#                         before parsing component and arch.
#   PROJECT_SLUG        Subdirectory name under pool/<component>/ (default: valkey)

set -euo pipefail

REPO_DIR="${REPO_DIR:?ERROR: REPO_DIR is required}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:?ERROR: ARTIFACTS_DIR is required}"
REPO_CODENAME="${REPO_CODENAME:?ERROR: REPO_CODENAME is required}"
REPO_ORIGIN="${REPO_ORIGIN:?ERROR: REPO_ORIGIN is required}"
REPO_LABEL="${REPO_LABEL:?ERROR: REPO_LABEL is required}"
REPO_DESCRIPTION="${REPO_DESCRIPTION:?ERROR: REPO_DESCRIPTION is required}"
GPG_KEY_ID="${GPG_KEY_ID:?ERROR: GPG_KEY_ID is required}"

REPO_SUITE="${REPO_SUITE:-stable}"
ARTIFACT_NAME_PREFIX="${ARTIFACT_NAME_PREFIX:-packages}"
RELEASE_TAG_FILTER="${RELEASE_TAG_FILTER:-}"
PROJECT_SLUG="${PROJECT_SLUG:-valkey}"

log() { printf '[assemble-apt-repo] %s\n' "$*" >&2; }
die() { printf '[assemble-apt-repo] ERROR: %s\n' "$*" >&2; exit 1; }

# ── Dependency checks ──────────────────────────────────────────────────────────

for cmd in dpkg-scanpackages dpkg-deb gzip xz gpg; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is not installed"
done

[[ -d "$ARTIFACTS_DIR" ]] || die "ARTIFACTS_DIR does not exist: $ARTIFACTS_DIR"

# ── Derive suite major (e.g. "7" from "valkey7") ──────────────────────────────

suite_major="${REPO_CODENAME#valkey}"
[[ "$suite_major" =~ ^[0-9]+$ ]] || die "Cannot derive numeric major from REPO_CODENAME=$REPO_CODENAME"

# ── Step 1: Copy .deb files into the pool ─────────────────────────────────────
#
# Pool path: <REPO_DIR>/pool/<component>/v/<slug>/<file>.deb
# This mirrors the standard Debian pool layout.

log "Copying artifacts into pool for suite ${REPO_CODENAME} (major ${suite_major})..."

components=()
architectures=()

for artifact_dir in "${ARTIFACTS_DIR}"/*; do
    [[ -d "$artifact_dir" ]] || continue

    artifact_name="$(basename "$artifact_dir")"

    if [[ -n "$RELEASE_TAG_FILTER" ]]; then
        if [[ "$artifact_name" != "${ARTIFACT_NAME_PREFIX}-${RELEASE_TAG_FILTER}-"* ]]; then
            log "Skipping $artifact_name (tag filter: $RELEASE_TAG_FILTER)"
            continue
        fi
        parse_name="${artifact_name#${ARTIFACT_NAME_PREFIX}-${RELEASE_TAG_FILTER}-}"
    else
        if [[ "$artifact_name" != "${ARTIFACT_NAME_PREFIX}-"* ]]; then
            log "Skipping $artifact_name (unexpected name)"
            continue
        fi
        parse_name="${artifact_name#${ARTIFACT_NAME_PREFIX}-}"
    fi

    # parse_name is now "<component>-<arch>"
    if [[ "$parse_name" =~ ^(.+)-([^-]+)$ ]]; then
        component="${BASH_REMATCH[1]}"
        arch="${BASH_REMATCH[2]}"
    else
        die "Cannot parse component/arch from: $parse_name (artifact: $artifact_name)"
    fi

    shopt -s nullglob
    debs=( "$artifact_dir"/*.deb )
    shopt -u nullglob

    if [[ ${#debs[@]} -eq 0 ]]; then
        log "No .deb files in $artifact_dir, skipping"
        continue
    fi

    pool_dir="${REPO_DIR}/pool/${component}/v/${PROJECT_SLUG}"
    mkdir -p "$pool_dir"

    for deb in "${debs[@]}"; do
        dest="${pool_dir}/$(basename "$deb")"
        if [[ -f "$dest" ]]; then
            # Same filename already in pool — compare checksums before overwriting.
            if sha256sum --quiet --check <(sha256sum "$deb" | sed "s|${deb}|${dest}|") 2>/dev/null; then
                log "Pool already has $(basename "$deb") (identical), skipping copy"
                continue
            fi
            log "Replacing $(basename "$deb") in pool (checksum differs)"
        else
            log "Adding $(basename "$deb") to pool"
        fi
        cp "$deb" "$dest"
    done

    # Track which components and architectures are present.
    if [[ ! " ${components[*]} " =~ " ${component} " ]]; then
        components+=( "$component" )
    fi
    if [[ ! " ${architectures[*]} " =~ " ${arch} " ]]; then
        architectures+=( "$arch" )
    fi
done

# Also discover existing pool directories for this suite so we can rebuild the
# full index even when only a subset of components/arches was built this run.
for pool_comp_dir in "${REPO_DIR}/pool"/*/; do
    [[ -d "$pool_comp_dir" ]] || continue
    c="$(basename "$pool_comp_dir")"
    if [[ ! " ${components[*]} " =~ " ${c} " ]]; then
        components+=( "$c" )
    fi
done

[[ ${#components[@]} -gt 0 ]] || die "No components found in pool under $REPO_DIR/pool"

# Discover all architectures from existing pool files if not captured above.
for pool_comp_dir in "${REPO_DIR}/pool"/*/; do
    [[ -d "$pool_comp_dir" ]] || continue
    while IFS= read -r deb; do
        a="$(dpkg-deb --field "$deb" Architecture 2>/dev/null)" || continue
        [[ "$a" == "all" ]] && continue
        if [[ ! " ${architectures[*]} " =~ " ${a} " ]]; then
            architectures+=( "$a" )
        fi
    done < <(find "$pool_comp_dir" -name '*.deb' 2>/dev/null)
done

[[ ${#architectures[@]} -gt 0 ]] || die "No architectures discovered"

log "Components : ${components[*]}"
log "Architectures: ${architectures[*]}"

# ── Step 2: Generate Packages files ───────────────────────────────────────────
#
# For each component × arch, scan the pool and produce a Packages file that
# includes ONLY packages whose upstream version major matches the suite major.
# Using --multiversion so all versions are listed (not just the newest).

log "Generating Packages files for suite ${REPO_CODENAME}..."

for component in "${components[@]}"; do
    pool_slug_dir="${REPO_DIR}/pool/${component}/v/${PROJECT_SLUG}"
    [[ -d "$pool_slug_dir" ]] || continue

    for arch in "${architectures[@]}"; do
        dist_dir="${REPO_DIR}/dists/${REPO_CODENAME}/${component}/binary-${arch}"
        mkdir -p "$dist_dir"

        # Build a temporary directory containing only the .deb files that
        # belong to this architecture AND this suite's major version.
        tmp_scan_dir="$(mktemp -d)"

        while IFS= read -r deb; do
            deb_fields="$(dpkg-deb --field "$deb" Architecture Version 2>/dev/null)" || continue
            deb_arch="$(awk '/^Architecture:/ {print $2; exit}' <<< "$deb_fields")"
            deb_ver="$(awk '/^Version:/ {print $2; exit}' <<< "$deb_fields")"
            [[ -n "$deb_arch" && -n "$deb_ver" ]] || continue
            [[ "$deb_arch" == "$arch" || "$deb_arch" == "all" ]] || continue
            # Strip Debian revision to get the upstream version, e.g. "7.2.11-1~noble" → "7.2.11"
            upstream_ver="${deb_ver%%-*}"
            deb_major="${upstream_ver%%.*}"
            [[ "$deb_major" == "$suite_major" ]] || continue

            # Symlink into the temp dir; dpkg-scanpackages will see a flat dir
            # of symlinks — the Filename: entries are rewritten via sed below.
            link_name="${tmp_scan_dir}/$(basename "$deb")"
            ln -sf "$(realpath "$deb")" "$link_name"
        done < <(find "$pool_slug_dir" -name '*.deb' | sort -V)

        shopt -s nullglob
        scan_debs=( "$tmp_scan_dir"/*.deb )
        shopt -u nullglob

        if [[ ${#scan_debs[@]} -eq 0 ]]; then
            log "No packages for ${component}/binary-${arch} in suite ${REPO_CODENAME}, skipping"
            rm -rf "$tmp_scan_dir"
            continue
        fi

        log "Scanning ${#scan_debs[@]} package(s) for ${REPO_CODENAME}/${component}/binary-${arch}"

        # dpkg-scanpackages prints Filename relative to the path argument.
        # We scan a temp dir of symlinks, so we must rewrite Filename: entries
        # to point at the real pool path.
        dpkg-scanpackages --multiversion "$tmp_scan_dir" /dev/null 2>/dev/null \
            | sed "s|Filename: ${tmp_scan_dir}/|Filename: pool/${component}/v/${PROJECT_SLUG}/|g" \
            > "${dist_dir}/Packages"

        gzip  -9 -k -f "${dist_dir}/Packages"
        xz    -9 -k -f "${dist_dir}/Packages"

        rm -rf "$tmp_scan_dir"
        log "Generated ${dist_dir}/Packages ($(wc -l < "${dist_dir}/Packages") lines)"
    done
done

# ── Step 3: Generate Release file ─────────────────────────────────────────────

log "Generating Release file for suite ${REPO_CODENAME}..."

suite_dist_dir="${REPO_DIR}/dists/${REPO_CODENAME}"
mkdir -p "$suite_dist_dir"

# Build the components and architectures lines from what was actually indexed.
indexed_components=()
indexed_architectures=()

for component in "${components[@]}"; do
    for arch in "${architectures[@]}"; do
        pkgs_file="${suite_dist_dir}/${component}/binary-${arch}/Packages"
        [[ -f "$pkgs_file" ]] || continue
        if [[ ! " ${indexed_components[*]} " =~ " ${component} " ]]; then
            indexed_components+=( "$component" )
        fi
        if [[ ! " ${indexed_architectures[*]} " =~ " ${arch} " ]]; then
            indexed_architectures+=( "$arch" )
        fi
    done
done

[[ ${#indexed_components[@]} -gt 0 ]] || die "No Packages files were generated for suite ${REPO_CODENAME}"

DATE="$(date -u '+%a, %d %b %Y %H:%M:%S UTC')"

cat > "${suite_dist_dir}/Release" <<EOF
Origin: ${REPO_ORIGIN}
Label: ${REPO_LABEL}
Suite: ${REPO_SUITE}
Codename: ${REPO_CODENAME}
Date: ${DATE}
Architectures: ${indexed_architectures[*]}
Components: ${indexed_components[*]}
Description: ${REPO_DESCRIPTION}
EOF

# Append MD5Sum, SHA1, SHA256, SHA512 checksums of all index files.
for hash_algo in MD5Sum SHA1 SHA256 SHA512; do
    case "$hash_algo" in
        MD5Sum) cmd="md5sum"    ;;
        SHA1)   cmd="sha1sum"   ;;
        SHA256) cmd="sha256sum" ;;
        SHA512) cmd="sha512sum" ;;
    esac

    printf '%s:\n' "$hash_algo" >> "${suite_dist_dir}/Release"

    for component in "${indexed_components[@]}"; do
        for arch in "${indexed_architectures[@]}"; do
            for fname in Packages Packages.gz Packages.xz; do
                fpath="${suite_dist_dir}/${component}/binary-${arch}/${fname}"
                [[ -f "$fpath" ]] || continue
                hash_val="$($cmd "$fpath" | awk '{print $1}')"
                size="$(wc -c < "$fpath")"
                rel_path="${component}/binary-${arch}/${fname}"
                printf ' %s %8d %s\n' "$hash_val" "$size" "$rel_path" \
                    >> "${suite_dist_dir}/Release"
            done
        done
    done
done

log "Generated ${suite_dist_dir}/Release"

# ── Step 4: Sign Release file ──────────────────────────────────────────────────

log "Signing Release file for suite ${REPO_CODENAME}..."

# Detached signature → Release.gpg
gpg --batch --yes \
    --local-user "$GPG_KEY_ID" \
    --armor --detach-sign \
    --output "${suite_dist_dir}/Release.gpg" \
    "${suite_dist_dir}/Release"

# Inline cleartext signature → InRelease
gpg --batch --yes \
    --local-user "$GPG_KEY_ID" \
    --armor --clearsign \
    --output "${suite_dist_dir}/InRelease" \
    "${suite_dist_dir}/Release"

log "Signed: Release.gpg and InRelease"

log "APT repository assembly completed for suite ${REPO_CODENAME}"
