#!/usr/bin/env bash
# deploy-apt-repo.sh
#
# Deploy built .deb artifacts to Cloudflare R2 via s3sync (nidor1998/s3sync).
# Handles: pull existing state from R2, assemble, index generation, sync back.
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
#   PAGES_URL              e.g. "https://apt.example.com"
#   ARTIFACTS_DIR          Path to downloaded artifact directories
#   R2_ENDPOINT_URL        e.g. "https://<account_id>.r2.cloudflarestorage.com"
#   R2_BUCKET              R2 bucket name
#   R2_ACCESS_KEY_ID       R2 API token (Access Key ID)
#   R2_SECRET_ACCESS_KEY   R2 API token (Secret Access Key)
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
#   PACKAGES_DIR           Base directory containing per-package logo folders. Default: packages

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
R2_ENDPOINT_URL="${R2_ENDPOINT_URL:?ERROR: R2_ENDPOINT_URL is required}"
R2_BUCKET="${R2_BUCKET:?ERROR: R2_BUCKET is required}"
R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:?ERROR: R2_ACCESS_KEY_ID is required}"
R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:?ERROR: R2_SECRET_ACCESS_KEY is required}"

: "${PROJECT_README_URL:=${REPO_URL}/blob/main/packages/${PROJECT_SLUG}/README.md}"
: "${PROJECT_LOGO_PATH:=}"
: "${APT_SUITE_PREFIX:=${PROJECT_SLUG}}"
: "${APT_INSTALL_PACKAGE:=${PROJECT_SLUG}}"
: "${APT_COMPONENT:=}"
: "${PACKAGES_LIST:=packages.list}"
: "${PACKAGES_DIR:=packages}"

export PROJECT_NAME PROJECT_SLUG PROJECT_UPSTREAM_URL PROJECT_README_URL
export PROJECT_LOGO_PATH REPO_URL PAGES_URL APT_SUITE_PREFIX APT_INSTALL_PACKAGE
export APT_COMPONENT GPG_KEY_ID

log() { printf '[deploy] %s\n' "$*" >&2; }
die() { printf '[deploy] ERROR: %s\n' "$*" >&2; exit 1; }

[[ -d "$ARTIFACTS_DIR" ]] || die "ARTIFACTS_DIR does not exist: $ARTIFACTS_DIR"
[[ -f "$PACKAGES_LIST" ]] || die "PACKAGES_LIST not found: $PACKAGES_LIST"

command -v s3sync >/dev/null 2>&1 || die "'s3sync' is not installed"

export BUILD_DATE
BUILD_DATE="$(date -u '+%Y-%m-%d %H:%M UTC')"

# ── s3sync helpers ──
_s3sync_pull() {
    s3sync \
        --source-endpoint-url   "$R2_ENDPOINT_URL" \
        --source-access-key     "$R2_ACCESS_KEY_ID" \
        --source-secret-access-key "$R2_SECRET_ACCESS_KEY" \
        --source-region         auto \
        --show-no-progress \
        --disable-etag-verify \
        "s3://${R2_BUCKET}/" repo/
}

_s3sync_push() {
    s3sync \
        --target-endpoint-url   "$R2_ENDPOINT_URL" \
        --target-access-key     "$R2_ACCESS_KEY_ID" \
        --target-secret-access-key "$R2_SECRET_ACCESS_KEY" \
        --target-region         auto \
        --show-no-progress \
        --delete \
        repo/ "s3://${R2_BUCKET}/"
}

# ── Pull existing repo state from R2 ──
log "Pulling existing repo state from R2 (s3://${R2_BUCKET})..."
mkdir -p repo
_s3sync_pull

rm -rf repo/conf repo/db

# ── GPG public key ──
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
PACKAGES_DIR="${PACKAGES_DIR}" \
OUTPUT_PATH="./repo/index.html" \
bash scripts/generate-root-index.sh "${root_args[@]}"

# ── Sync to R2 ──
log "Syncing repo to R2 (s3://${R2_BUCKET})..."
_s3sync_push

log "✓ Deployed ${PROJECT_NAME} ${LATEST_TAG} to s3://${R2_BUCKET}"
