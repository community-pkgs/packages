#!/usr/bin/env bash
# assemble-apt-repo.sh
#
# Assemble a signed APT repository from downloaded .deb artifacts using reprepro.
#
# This script keeps reprepro distribution metadata in two layers:
#   1. conf/distributions.d/<codename>
#      One generated block per published codename / major channel.
#   2. conf/distributions
#      Final file composed from all files in distributions.d/.
#
# This avoids in-place block editing of conf/distributions and makes each
# codename's metadata easy to inspect and regenerate independently.
#
# Expected artifact naming convention:
#   packages-<component>-<arch>
#
# When RELEASE_TAG_FILTER is set, artifacts are expected to be named:
#   packages-<release_tag>-<component>-<arch>
# Only artifacts matching that release tag are processed, and the tag prefix
# is stripped before the component/arch are parsed.
#
# In the current repository layout:
# - component = distro codename (e.g. noble, trixie)
# - suite/codename = product major channel (e.g. valkey9)
#
# Required environment variables:
#   REPO_DIR            Repository root directory to populate (e.g. repo)
#   ARTIFACTS_DIR       Directory containing downloaded artifact subdirectories
#   REPO_CODENAME       Reprepro Codename/Suite to publish into (e.g. valkey9)
#   REPO_ORIGIN         Origin field for reprepro distributions
#   REPO_LABEL          Label field for reprepro distributions
#   REPO_DESCRIPTION    Description field for reprepro distributions
#   GPG_KEY_ID          GPG key ID/fingerprint used by reprepro SignWith
#
# Optional environment variables:
#   REPO_SUITE          Suite field in reprepro distributions (default: stable)
#   DISTRIBUTIONS_DIR   Path to per-codename metadata directory
#                       (default: <REPO_DIR>/conf/distributions.d)
#   DISTRIBUTIONS_FILE  Path to final conf/distributions file
#                       (default: <REPO_DIR>/conf/distributions)
#   ARTIFACT_NAME_PREFIX  Prefix for artifact directories (default: packages)
#   RELEASE_TAG_FILTER    When set, only process artifacts whose name contains
#                         this release tag after the prefix, and strip it before
#                         parsing the component and arch.
#                         Example: RELEASE_TAG_FILTER=9.0.3 processes
#                         packages-9.0.3-noble-amd64 as component=noble arch=amd64
#
# Example:
#   REPO_DIR=repo \
#   ARTIFACTS_DIR=./downloaded-artifacts \
#   REPO_CODENAME=valkey9 \
#   REPO_ORIGIN="Valkey APT Repository" \
#   REPO_LABEL="Valkey" \
#   REPO_DESCRIPTION="Valkey APT Repository" \
#   GPG_KEY_ID="$GPG_KEY_ID" \
#   scripts/assemble-apt-repo.sh

set -euo pipefail

REPO_DIR="${REPO_DIR:?ERROR: REPO_DIR is required}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:?ERROR: ARTIFACTS_DIR is required}"
REPO_CODENAME="${REPO_CODENAME:?ERROR: REPO_CODENAME is required}"
REPO_ORIGIN="${REPO_ORIGIN:?ERROR: REPO_ORIGIN is required}"
REPO_LABEL="${REPO_LABEL:?ERROR: REPO_LABEL is required}"
REPO_DESCRIPTION="${REPO_DESCRIPTION:?ERROR: REPO_DESCRIPTION is required}"
GPG_KEY_ID="${GPG_KEY_ID:?ERROR: GPG_KEY_ID is required}"

REPO_SUITE="${REPO_SUITE:-stable}"
DISTRIBUTIONS_DIR="${DISTRIBUTIONS_DIR:-${REPO_DIR}/conf/distributions.d}"
DISTRIBUTIONS_FILE="${DISTRIBUTIONS_FILE:-${REPO_DIR}/conf/distributions}"
ARTIFACT_NAME_PREFIX="${ARTIFACT_NAME_PREFIX:-packages}"
RELEASE_TAG_FILTER="${RELEASE_TAG_FILTER:-}"

log() {
    printf '[assemble-apt-repo] %s\n' "$*" >&2
}

die() {
    printf '[assemble-apt-repo] ERROR: %s\n' "$*" >&2
    exit 1
}

contains() {
    local needle="$1"
    shift || true
    local item

    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done

    return 1
}

render_distribution_block() {
    local output_path="$1"
    local components_line="$2"
    local architectures_line="$3"

    cat > "$output_path" <<EOF
Origin: $REPO_ORIGIN
Label: $REPO_LABEL
Suite: $REPO_SUITE
Codename: $REPO_CODENAME
Components: $components_line
Architectures: $architectures_line
Description: $REPO_DESCRIPTION
SignWith: $GPG_KEY_ID
EOF
}

compose_distributions_file() {
    local tmp_file
    local first=1
    local block_file

    tmp_file="$(mktemp)"

    # sort -V ensures deterministic ordering: valkey8 < valkey9 < valkey10.
    while IFS= read -r block_file; do
        [[ -f "$block_file" ]] || continue

        if [[ $first -eq 0 ]]; then
            printf '\n' >> "$tmp_file"
        fi

        cat "$block_file" >> "$tmp_file"
        first=0
    done < <(find "$DISTRIBUTIONS_DIR" -maxdepth 1 -type f | LC_ALL=C sort -V)

    [[ $first -eq 0 ]] || die "No per-codename distribution blocks found in $DISTRIBUTIONS_DIR"

    mv "$tmp_file" "$DISTRIBUTIONS_FILE"
}

command -v reprepro >/dev/null 2>&1 || die "reprepro is not installed or not in PATH"
[[ -d "$ARTIFACTS_DIR" ]] || die "ARTIFACTS_DIR does not exist: $ARTIFACTS_DIR"

mkdir -p "${REPO_DIR}/conf" "$DISTRIBUTIONS_DIR"

components=()
architectures=()
artifact_dirs=()
artifact_components=()

# Read existing architectures and components for this codename from the
# previously-written per-codename block (present when the apt branch was
# checked out into REPO_DIR).  We merge them with whatever is found in the
# current artifacts so that packages for architectures / components that were
# not built this run are NOT silently dropped from conf/distributions — which
# would cause reprepro to error with "unused database".
existing_block="${DISTRIBUTIONS_DIR}/${REPO_CODENAME}"
if [[ -f "$existing_block" ]]; then
    while IFS= read -r line; do
        if [[ "$line" =~ ^Architectures:[[:space:]]*(.+)$ ]]; then
            read -ra _arches <<< "${BASH_REMATCH[1]}"
            for _a in "${_arches[@]}"; do
                if ! contains "$_a" "${architectures[@]}"; then
                    architectures+=( "$_a" )
                fi
            done
        fi
        if [[ "$line" =~ ^Components:[[:space:]]*(.+)$ ]]; then
            read -ra _comps <<< "${BASH_REMATCH[1]}"
            for _c in "${_comps[@]}"; do
                if ! contains "$_c" "${components[@]}"; then
                    components+=( "$_c" )
                fi
            done
        fi
    done < "$existing_block"
    log "Loaded existing architectures from $existing_block: ${architectures[*]:-none}"
    log "Loaded existing components from $existing_block: ${components[*]:-none}"
fi

for artifact_dir in "${ARTIFACTS_DIR}"/*; do
    [[ -d "$artifact_dir" ]] || continue

    artifact_name="$(basename "$artifact_dir")"

    if [[ -n "$RELEASE_TAG_FILTER" ]]; then
        # When a release tag filter is set, only process artifacts that match
        # packages-<tag>-<component>-<arch> and strip the tag before parsing.
        if [[ "$artifact_name" != "${ARTIFACT_NAME_PREFIX}-${RELEASE_TAG_FILTER}-"* ]]; then
            log "Skipping artifact $artifact_name (does not match tag filter $RELEASE_TAG_FILTER)"
            continue
        fi
        parse_name="${artifact_name#${ARTIFACT_NAME_PREFIX}-${RELEASE_TAG_FILTER}-}"
        if [[ "$parse_name" =~ ^(.+)-([^-]+)$ ]]; then
            component="${BASH_REMATCH[1]}"
            arch="${BASH_REMATCH[2]}"
        else
            die "Unexpected artifact name format after stripping tag: $parse_name (from $artifact_name)"
        fi
    elif [[ "$artifact_name" =~ ^${ARTIFACT_NAME_PREFIX}-(.+)-([^-]+)$ ]]; then
        component="${BASH_REMATCH[1]}"
        arch="${BASH_REMATCH[2]}"
    else
        die "Unexpected artifact name format: $artifact_name"
    fi

    log "Processing artifact dir=$artifact_dir component=$component arch=$arch"

    shopt -s nullglob
    debs=( "$artifact_dir"/*.deb )
    shopt -u nullglob

    if [[ ${#debs[@]} -eq 0 ]]; then
        log "No .deb files in $artifact_dir, skipping"
        continue
    fi

    artifact_dirs+=( "$artifact_dir" )
    artifact_components+=( "$component" )

    if ! contains "$component" "${components[@]}"; then
        components+=( "$component" )
    fi

    if ! contains "$arch" "${architectures[@]}"; then
        architectures+=( "$arch" )
    fi
done

[[ ${#artifact_dirs[@]} -gt 0 ]] || die "No package artifacts were included from $ARTIFACTS_DIR"

components_line="${components[*]}"
architectures_line="${architectures[*]}"

render_distribution_block \
    "${DISTRIBUTIONS_DIR}/${REPO_CODENAME}" \
    "$components_line" \
    "$architectures_line"

compose_distributions_file

# Include packages while preserving all existing versions in the index.
#
# The only case requiring removal first is a same-version rebuild: when the
# same package+version is already indexed but with a different checksum,
# reprepro refuses to overwrite it.  We handle that with removefilter (which
# removes only that specific version, leaving other versions intact) followed
# by deleteunreferenced to purge only the stale pool file.
#
# All other versions already in the index are left untouched, so users can
# still install older releases with apt install pkg=old_version.

log "Including packages (preserving existing versions in index)..."
for i in "${!artifact_dirs[@]}"; do
    artifact_dir="${artifact_dirs[$i]}"
    component="${artifact_components[$i]}"

    shopt -s nullglob
    debs=( "$artifact_dir"/*.deb )
    shopt -u nullglob

    for deb in "${debs[@]}"; do
        pkg="$(dpkg-deb --field "$deb" Package)"
        new_ver="$(dpkg-deb --field "$deb" Version)"

        # Check whether this exact version is already in the index.
        if reprepro -b "$REPO_DIR" --component "$component" \
                list "$REPO_CODENAME" "$pkg" 2>/dev/null \
                | grep -qF "$new_ver"; then
            # Same-version rebuild: remove only this version so the new .deb
            # (potentially with a different checksum) can be added cleanly.
            # removefilter removes only the matching version; all others stay.
            log "Same-version rebuild: removing $pkg $new_ver from ${REPO_CODENAME}/${component}"
            reprepro -b "$REPO_DIR" --component "$component" \
                removefilter "$REPO_CODENAME" "Package (= ${pkg}), Version (= ${new_ver})"
            reprepro -b "$REPO_DIR" deleteunreferenced
        fi

        log "Including $pkg $new_ver into ${REPO_CODENAME}/${component}"
        reprepro -b "$REPO_DIR" --component "$component" includedeb "$REPO_CODENAME" "$deb"
    done
done

# Re-index any .deb files present in the pool that are not yet referenced by
# the current REPO_CODENAME suite.  This restores versions that were previously
# dropped from the index (e.g. due to out-of-order manual builds) without
# requiring a fresh CI run for each old version.
#
# Guards:
#   - Iterates over every component that belongs to this suite (not just the
#     last one from the artifact loop above).
#   - Only considers .deb files whose upstream major version matches the suite
#     major (e.g. pool files with version 8.x are never added to valkey9).
log "Re-indexing unreferenced pool files for ${REPO_CODENAME}..."
suite_major="${REPO_CODENAME#valkey}"   # "9" from "valkey9"

for idx_component in "${components[@]}"; do
    pool_component_dir="${REPO_DIR}/pool/${idx_component}"
    [[ -d "$pool_component_dir" ]] || continue

    while IFS= read -r pool_deb; do
        pool_pkg="$(dpkg-deb --field "$pool_deb" Package 2>/dev/null)" || continue
        pool_ver="$(dpkg-deb --field "$pool_deb" Version 2>/dev/null)" || continue

        # Skip if the major version doesn't match the suite
        # e.g. "9.0.3-1~noble" → major "9"
        pool_major="${pool_ver%%.*}"
        if [[ "$pool_major" != "$suite_major" ]]; then
            continue
        fi

        # Skip if already indexed
        if reprepro -b "$REPO_DIR" --component "$idx_component" \
                list "$REPO_CODENAME" "$pool_pkg" 2>/dev/null \
                | grep -qF "$pool_ver"; then
            continue
        fi

        log "Re-indexing $pool_pkg $pool_ver ($idx_component) from pool"
        reprepro -b "$REPO_DIR" --component "$idx_component" \
            includedeb "$REPO_CODENAME" "$pool_deb" 2>/dev/null || \
            log "WARNING: could not re-index $pool_deb (skipping)"
    done < <(find "$pool_component_dir" -name '*.deb' | sort -V)
done

# Re-export all codenames, not just REPO_CODENAME, so that pre-existing suites
# (e.g. valkey8 from a previous run) stay signed with the current key.
grep '^Codename:' "$DISTRIBUTIONS_FILE" | awk '{print $2}' | while read -r cn; do
    [[ -n "$cn" ]] || continue
    log "Exporting $cn"
    reprepro -b "$REPO_DIR" export "$cn"
done

log "APT repository assembly completed in $REPO_DIR"
