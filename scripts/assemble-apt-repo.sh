#!/usr/bin/env bash
# assemble-apt-repo.sh
#
# Assemble a signed APT repository from downloaded .deb artifacts.
#
# Uses dpkg-scanpackages --multiversion so users can pin any specific version:
#   apt install valkey-server=7.2.11-1~noble
#
# Pool layout:
#   <REPO_DIR>/pool/<component>/<first_letter>/<project_slug>/<package>_<version>_<arch>.deb
#
# Dist layout:
#   <REPO_DIR>/dists/<suite>/<component>/binary-<arch>/Packages[.gz|.xz]
#   <REPO_DIR>/dists/<suite>/Release[.gpg]
#   <REPO_DIR>/dists/<suite>/InRelease
#
# Required:
#   REPO_DIR            Repository root directory (e.g. repo)
#   ARTIFACTS_DIR       Directory containing downloaded artifact subdirectories
#   REPO_CODENAME       Suite/Codename to publish into (e.g. valkey9, etcd)
#   REPO_ORIGIN         Origin field in Release
#   REPO_LABEL          Label field in Release
#   REPO_DESCRIPTION    Description field in Release
#   GPG_KEY_ID          GPG key ID used for signing
#
# Optional:
#   REPO_SUITE              Suite field in Release (default: stable)
#   ARTIFACT_NAME_PREFIX    Prefix for artifact dirs (default: packages)
#   RELEASE_TAG_FILTER      Only process artifact dirs containing this tag
#   PROJECT_SLUG            Subdirectory name under pool/<component>/ (default: valkey)

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
ARTIFACT_COMPONENT_OVERRIDE="${ARTIFACT_COMPONENT_OVERRIDE:-}"

log() { printf '[assemble-apt-repo] %s\n' "$*" >&2; }
die() { printf '[assemble-apt-repo] ERROR: %s\n' "$*" >&2; exit 1; }

for cmd in dpkg-scanpackages dpkg-deb gzip xz gpg; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is not installed"
done

[[ -d "$ARTIFACTS_DIR" ]] || die "ARTIFACTS_DIR does not exist: $ARTIFACTS_DIR"

# When REPO_CODENAME has no trailing number, version filtering is disabled.
if [[ "${REPO_CODENAME}" =~ ([0-9]+)$ ]]; then
    suite_major="${BASH_REMATCH[1]}"
    log "Suite major version: ${suite_major}"
else
    suite_major=""
    log "No numeric suite major in '${REPO_CODENAME}' — version filtering disabled"
fi

log "Copying artifacts into pool for suite ${REPO_CODENAME}..."

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
        parse_name="${artifact_name#"${ARTIFACT_NAME_PREFIX}"-"${RELEASE_TAG_FILTER}"-}"
    else
        if [[ "$artifact_name" != "${ARTIFACT_NAME_PREFIX}-"* ]]; then
            log "Skipping $artifact_name (unexpected name)"
            continue
        fi
        parse_name="${artifact_name#"${ARTIFACT_NAME_PREFIX}"-}"
    fi

    if [[ "$parse_name" =~ ^(.+)-([^-]+)$ ]]; then
        component="${BASH_REMATCH[1]}"
        arch="${BASH_REMATCH[2]}"
    else
        die "Cannot parse component/arch from: $parse_name (artifact: $artifact_name)"
    fi

    [[ -n "$ARTIFACT_COMPONENT_OVERRIDE" ]] && component="$ARTIFACT_COMPONENT_OVERRIDE"

    shopt -s nullglob
    debs=( "$artifact_dir"/*.deb )
    shopt -u nullglob

    if [[ ${#debs[@]} -eq 0 ]]; then
        log "No .deb files in $artifact_dir, skipping"
        continue
    fi

    pool_dir="${REPO_DIR}/pool/${component}/${PROJECT_SLUG:0:1}/${PROJECT_SLUG}"
    mkdir -p "$pool_dir"

    for deb in "${debs[@]}"; do
        dest="${pool_dir}/$(basename "$deb")"
        if [[ -f "$dest" ]]; then
            # Skip identical files — different builds of the same tag can race.
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

    [[ ! " ${components[*]} " == *" ${component} "* ]] && components+=( "$component" )
    [[ ! " ${architectures[*]} " == *" ${arch} "* ]]   && architectures+=( "$arch" )
done

for pool_comp_dir in "${REPO_DIR}/pool"/*/; do
    [[ -d "$pool_comp_dir" ]] || continue
    c="$(basename "$pool_comp_dir")"
    [[ ! " ${components[*]} " == *" ${c} "* ]] && components+=( "$c" )
done

[[ ${#components[@]} -gt 0 ]] || die "No components found in pool under $REPO_DIR/pool"

for pool_comp_dir in "${REPO_DIR}/pool"/*/; do
    [[ -d "$pool_comp_dir" ]] || continue
    while IFS= read -r deb; do
        a="$(dpkg-deb --field "$deb" Architecture 2>/dev/null)" || continue
        [[ "$a" == "all" ]] && continue
        [[ ! " ${architectures[*]} " == *" ${a} "* ]] && architectures+=( "$a" )
    done < <(find "$pool_comp_dir" -name '*.deb' 2>/dev/null)
done

[[ ${#architectures[@]} -gt 0 ]] || die "No architectures discovered"

log "Components: ${components[*]}"
log "Architectures: ${architectures[*]}"

log "Generating Packages files for suite ${REPO_CODENAME}..."

for component in "${components[@]}"; do
    pool_slug_dir="${REPO_DIR}/pool/${component}/${PROJECT_SLUG:0:1}/${PROJECT_SLUG}"
    [[ -d "$pool_slug_dir" ]] || continue

    for arch in "${architectures[@]}"; do
        dist_dir="${REPO_DIR}/dists/${REPO_CODENAME}/${component}/binary-${arch}"
        mkdir -p "$dist_dir"

        tmp_scan_dir="$(mktemp -d)"

        while IFS= read -r deb; do
            deb_fields="$(dpkg-deb --field "$deb" Architecture Version 2>/dev/null)" || continue
            deb_arch="$(awk '/^Architecture:/ {print $2; exit}' <<< "$deb_fields")"
            deb_ver="$(awk '/^Version:/ {print $2; exit}' <<< "$deb_fields")"
            [[ -n "$deb_arch" && -n "$deb_ver" ]] || continue
            [[ "$deb_arch" == "$arch" || "$deb_arch" == "all" ]] || continue
            if [[ -n "$suite_major" ]]; then
                upstream_ver="${deb_ver%%-*}"
                deb_major="${upstream_ver%%.*}"
                [[ "$deb_major" == "$suite_major" ]] || continue
            fi

            # Symlink into a flat temp dir so dpkg-scanpackages sees one directory;
            # Filename: entries are rewritten below to point at the real pool path.
            ln -sf "$(realpath "$deb")" "${tmp_scan_dir}/$(basename "$deb")"
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

        dpkg-scanpackages --multiversion "$tmp_scan_dir" /dev/null 2>/dev/null \
            | sed "s|Filename: ${tmp_scan_dir}/|Filename: pool/${component}/${PROJECT_SLUG:0:1}/${PROJECT_SLUG}/|g" \
            > "${dist_dir}/Packages"

        gzip -9 -k -f "${dist_dir}/Packages"
        xz   -9 -k -f "${dist_dir}/Packages"

        rm -rf "$tmp_scan_dir"
        log "Generated ${dist_dir}/Packages ($(wc -l < "${dist_dir}/Packages") lines)"
    done
done

log "Generating Release file for suite ${REPO_CODENAME}..."

suite_dist_dir="${REPO_DIR}/dists/${REPO_CODENAME}"
mkdir -p "$suite_dist_dir"

indexed_components=()
indexed_architectures=()

for component in "${components[@]}"; do
    for arch in "${architectures[@]}"; do
        pkgs_file="${suite_dist_dir}/${component}/binary-${arch}/Packages"
        [[ -f "$pkgs_file" ]] || continue
        [[ ! " ${indexed_components[*]} "    == *" ${component} "* ]] && indexed_components+=( "$component" )
        [[ ! " ${indexed_architectures[*]} " == *" ${arch} "* ]]      && indexed_architectures+=( "$arch" )
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
                printf ' %s %8d %s\n' "$hash_val" "$size" "${component}/binary-${arch}/${fname}" \
                    >> "${suite_dist_dir}/Release"
            done
        done
    done
done

log "Generated ${suite_dist_dir}/Release"

log "Signing Release file for suite ${REPO_CODENAME}..."

gpg --batch --yes \
    --local-user "$GPG_KEY_ID" \
    --armor --detach-sign \
    --output "${suite_dist_dir}/Release.gpg" \
    "${suite_dist_dir}/Release"

gpg --batch --yes \
    --local-user "$GPG_KEY_ID" \
    --armor --clearsign \
    --output "${suite_dist_dir}/InRelease" \
    "${suite_dist_dir}/Release"

log "Signed: Release.gpg and InRelease"
log "Done: ${REPO_CODENAME}"
