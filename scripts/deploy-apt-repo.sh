#!/usr/bin/env bash
# deploy-apt-repo.sh
#
# Deploy built .deb artifacts to the apt branch.
# Handles: worktree checkout, assemble, index generation, commit, push with retry.
#
# Required:
#   PROJECT_NAME           e.g. "Valkey"
#   PROJECT_SLUG           e.g. "valkey"
#   PROJECT_UPSTREAM_URL   e.g. "https://github.com/valkey-io/valkey"
#   NEW_RELEASES           JSON array from check-release.sh
#   ALL_RELEASES           JSON array from check-release.sh
#   LATEST_TAG             Highest tag from check-release.sh
#   GPG_KEY_ID             GPG key ID for signing
#   REPO_URL               e.g. "https://github.com/owner/repo"
#   PAGES_URL              e.g. "https://owner.github.io/repo"
#   ARTIFACTS_DIR          Path to downloaded artifact directories
#
# Optional:
#   PROJECT_README_URL     Default: REPO_URL/blob/main/packages/PROJECT_SLUG/README.md
#   PROJECT_LOGO_PATH      Square SVG logo path
#   APT_SUITE_PREFIX       Default: PROJECT_SLUG
#   APT_INSTALL_PACKAGE    Default: PROJECT_SLUG
#   APT_COMPONENT          When set, passed to assemble-apt-repo.sh as a fixed component
#                          name (e.g. "main" for arch-independent packages like etcd).
#                          When unset, component is derived from artifact directory names.
#   PACKAGES_LIST          Path to packages.list for root index. Default: packages.list
#   MAX_ATTEMPTS           Retry count for push conflicts. Default: 5

set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:?ERROR: PROJECT_NAME is required}"
PROJECT_SLUG="${PROJECT_SLUG:?ERROR: PROJECT_SLUG is required}"
PROJECT_UPSTREAM_URL="${PROJECT_UPSTREAM_URL:?ERROR: PROJECT_UPSTREAM_URL is required}"
NEW_RELEASES="${NEW_RELEASES:?ERROR: NEW_RELEASES is required}"
ALL_RELEASES="${ALL_RELEASES:?ERROR: ALL_RELEASES is required}"
LATEST_TAG="${LATEST_TAG:?ERROR: LATEST_TAG is required}"
GPG_KEY_ID="${GPG_KEY_ID:?ERROR: GPG_KEY_ID is required}"
REPO_URL="${REPO_URL:?ERROR: REPO_URL is required}"
PAGES_URL="${PAGES_URL:?ERROR: PAGES_URL is required}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:?ERROR: ARTIFACTS_DIR is required}"

: "${PROJECT_README_URL:=${REPO_URL}/blob/main/packages/${PROJECT_SLUG}/README.md}"
: "${PROJECT_LOGO_PATH:=}"
: "${APT_SUITE_PREFIX:=${PROJECT_SLUG}}"
: "${APT_INSTALL_PACKAGE:=${PROJECT_SLUG}}"
: "${APT_COMPONENT:=}"
: "${PACKAGES_LIST:=packages.list}"
: "${MAX_ATTEMPTS:=5}"

export PROJECT_NAME PROJECT_SLUG PROJECT_UPSTREAM_URL PROJECT_README_URL
export PROJECT_LOGO_PATH REPO_URL PAGES_URL APT_SUITE_PREFIX APT_INSTALL_PACKAGE
export APT_COMPONENT GPG_KEY_ID

log() { printf '[deploy] %s\n' "$*" >&2; }
die() { printf '[deploy] ERROR: %s\n' "$*" >&2; exit 1; }

[[ -d "$ARTIFACTS_DIR" ]] || die "ARTIFACTS_DIR does not exist: $ARTIFACTS_DIR"
[[ -f "$PACKAGES_LIST" ]] || die "PACKAGES_LIST not found: $PACKAGES_LIST"

git config user.name  "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

export BUILD_DATE
BUILD_DATE="$(date -u '+%Y-%m-%d %H:%M UTC')"

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    log "=== Attempt ${attempt}/${MAX_ATTEMPTS} ==="

    rm -rf repo
    if git ls-remote --exit-code --heads origin apt >/dev/null 2>&1; then
        git fetch origin apt
        git worktree add repo origin/apt
    else
        git worktree add --orphan -b apt repo
    fi

    rm -rf repo/conf repo/db

    if [[ ! -f repo/public.asc ]]; then
        gpg --armor --export "$GPG_KEY_ID" > repo/public.asc
        log "Generated public.asc"
    fi

    # ── Assemble per-release ──
    echo "$NEW_RELEASES" | jq -c '.[]' | while IFS= read -r release; do
        TAG="$(echo "$release" | jq -r '.tag')"
        MAJOR="$(echo "$release" | jq -r '.major')"

        if [[ -n "$MAJOR" ]]; then
            CODENAME="${APT_SUITE_PREFIX}${MAJOR}"
        else
            CODENAME="${APT_SUITE_PREFIX}"
        fi

        log "Assembling ${CODENAME} for release ${TAG}"

        _assemble_env=(
            REPO_DIR="repo"
            ARTIFACTS_DIR="${ARTIFACTS_DIR}"
            RELEASE_TAG_FILTER="${TAG}"
            REPO_CODENAME="${CODENAME}"
            REPO_ORIGIN="${PROJECT_NAME} APT Repository"
            REPO_LABEL="${PROJECT_NAME}"
            REPO_DESCRIPTION="${PROJECT_NAME} APT Repository"
            GPG_KEY_ID="${GPG_KEY_ID}"
            PROJECT_SLUG="${PROJECT_SLUG}"
        )
        [[ -n "$APT_COMPONENT" ]] && _assemble_env+=(ARTIFACT_COMPONENT_OVERRIDE="${APT_COMPONENT}")
        env "${_assemble_env[@]}" bash scripts/assemble-apt-repo.sh
    done

    # ── Package index page ──
    APT_BRANCH_URL="${REPO_URL}/tree/apt" \
    RELEASES_JSON="${ALL_RELEASES}" \
    OUTPUT_PATH="./repo/${PROJECT_SLUG}/index.html" \
    bash scripts/generate-apt-index.sh

    # ── Root index ──
    root_args=()
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        root_args+=("$line")
    done < "$PACKAGES_LIST"

    REPO_TITLE="APT Package Repository" \
    REPO_DESCRIPTION="Unofficial Debian/Ubuntu packages built automatically from upstream releases." \
    OUTPUT_PATH="./repo/index.html" \
    bash scripts/generate-root-index.sh "${root_args[@]}"

    # ── Commit & push ──
    cd repo
    git add -A
    if git diff --cached --quiet; then
        log "Nothing to commit."
        cd ..
        git worktree remove repo --force
        break
    fi
    git commit -m "Update APT repo for ${PROJECT_NAME} ${LATEST_TAG}"

    if git push origin HEAD:apt; then
        log "✓ Deployed on attempt ${attempt}"
        cd ..
        git worktree remove repo --force
        break
    fi

    log "Push rejected — retrying..."
    cd ..
    git worktree remove repo --force

    if [[ $attempt -eq $MAX_ATTEMPTS ]]; then
        die "Failed to deploy after ${MAX_ATTEMPTS} attempts"
    fi

    sleep $((attempt * 10))
done
