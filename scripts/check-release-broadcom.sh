#!/usr/bin/env bash
# check-release-broadcom.sh — detect new releases from Broadcom's docs API.
#
# Broadcom publishes a stable "Latest" document for each product that is updated
# in-place when new versions are released. The document ID is stable — only the
# content (i.e. the ZIP URL inside) changes with each release.
#
# Usage:
#   BROADCOM_DOC_ID=1232745486 bash scripts/check-release-broadcom.sh
#
# Required:
#   BROADCOM_DOC_ID     Broadcom document ID for the "Latest ..." page.
#                       Find it on https://www.broadcom.com/support/download-search?dk=StorCLI
#                       by hovering over "Latest Storcli for all OS" — the link href is
#                       https://docs.broadcom.com/docs/<ID>
#
# Optional:
#   BROADCOM_DOC_TITLE  Expected document title for validation (substring match).
#                       Default: "Storcli"
#   STATE_FILE          JSON state file. Default: state/storcli.json
#   SUITE_NAME          APT suite name (informational). Default: storcli
#   ALWAYS_BUILD        Force has_new=true even if version unchanged. Default: false
#   FORCE_TAG           Skip API call, treat this tag as latest (requires FORCE_URL)
#   FORCE_URL           Direct ZIP URL to use with FORCE_TAG
#   GITHUB_OUTPUT       Set automatically by GitHub Actions runner
#
# Outputs (written to GITHUB_OUTPUT if set, otherwise printed to stdout):
#   has_new             true / false
#   new_releases        JSON: [{"tag":"7.3603.0000.0000","major":"","url":"https://..."}]
#   all_releases        JSON: same format, reflects current deployed state
#   latest_tag          e.g. 7.3603.0000.0000
#   latest_url          e.g. https://docs.broadcom.com/docs-and-downloads/...Storcli.zip

set -euo pipefail

BROADCOM_DOC_ID="${BROADCOM_DOC_ID:?ERROR: BROADCOM_DOC_ID is required (e.g. 1232745486)}"
BROADCOM_DOC_TITLE="${BROADCOM_DOC_TITLE:-Storcli}"
STATE_FILE="${STATE_FILE:-state/storcli.json}"
ALWAYS_BUILD="${ALWAYS_BUILD:-false}"
FORCE_TAG="${FORCE_TAG:-}"
FORCE_URL="${FORCE_URL:-}"

_api_url="https://docs.broadcom.com/api/document/download/${BROADCOM_DOC_ID}"
_search_url="https://www.broadcom.com/support/download-search?dk=StorCLI"

log()  { printf '[check-release-broadcom] %s\n' "$*" >&2; }
die()  { printf '[check-release-broadcom] ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf '[check-release-broadcom] WARNING: %s\n' "$*" >&2; }

emit_output() {
    local key="$1" value="$2"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
    else
        printf '%s=%s\n' "$key" "$value"
    fi
}

# Strip leading zeros from version: 007.3603.0000.0000 -> 7.3603.0000.0000
normalize_tag() {
    echo "$1" | sed 's/^0*//'
}

make_releases_json() {
    local tag="$1" url="$2"
    printf '[{"tag":"%s","major":"","url":"%s"}]' "$tag" "$url"
}

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        local content
        content="$(cat "$STATE_FILE")"
        if echo "$content" | jq -e 'type == "object"' > /dev/null 2>&1; then
            echo "$content"
            return
        fi
        warn "$STATE_FILE contains invalid JSON — treating as empty state"
    fi
    printf '{}'
}

save_state() {
    local tag="$1" url="$2"
    jq -n --arg t "$tag" --arg u "$url" '{"tag":$t,"url":$u}' > "$STATE_FILE"
    log "Saved $STATE_FILE: tag=$tag"
}

# ── FORCE_TAG mode ──
if [[ -n "$FORCE_TAG" ]]; then
    [[ -n "$FORCE_URL" ]] || die "FORCE_URL is required when FORCE_TAG is set"
    tag="$(normalize_tag "$FORCE_TAG")"
    log "Using FORCE_TAG: ${tag}  url: ${FORCE_URL}"
    releases="$(make_releases_json "$tag" "$FORCE_URL")"
    emit_output "has_new"      "true"
    emit_output "new_releases" "$releases"
    emit_output "all_releases" "$releases"
    emit_output "latest_tag"   "$tag"
    emit_output "latest_url"   "$FORCE_URL"
    log "Done — has_new=true latest_tag=${tag}"
    exit 0
fi

# ── Fetch metadata from Broadcom API ──
log "Fetching metadata from ${_api_url} ..."

_response=$(
    curl -fsSL --connect-timeout 15 --max-time 30 "$_api_url" 2>/dev/null
) || die "Failed to fetch metadata from Broadcom API: ${_api_url}
  This may be a transient network error, or the document ID may have changed.
  To find the current ID, visit:
    ${_search_url}
  Hover over \"Latest Storcli for all OS\" — the href is:
    https://docs.broadcom.com/docs/<NEW_ID>
  Then update BROADCOM_DOC_ID in the workflow."

# ── Validate response is valid JSON ──
if ! echo "$_response" | jq -e 'type == "object"' > /dev/null 2>&1; then
    die "Broadcom API returned non-JSON response. The API endpoint may have changed.
  Response (first 200 chars): ${_response:0:200}
  Check the current doc ID at: ${_search_url}"
fi

# ── Validate document title matches expected product ──
_doc_title=$(echo "$_response" | jq -r '.document_title // empty')
if [[ -z "$_doc_title" ]]; then
    die "API response missing 'document_title' field. API structure may have changed.
  Response: ${_response:0:300}"
fi

if ! echo "$_doc_title" | grep -qi "$BROADCOM_DOC_TITLE"; then
    die "Document title mismatch!
  Expected title containing: ${BROADCOM_DOC_TITLE}
  Got: ${_doc_title}
  Doc ID ${BROADCOM_DOC_ID} may point to a different document now.
  Visit ${_search_url} to find the correct doc ID for \"Latest Storcli for all OS\"."
fi

log "Document: \"${_doc_title}\""

# ── Extract ZIP URL ──
_raw_url=$(echo "$_response" | jq -r '.url // empty')

if [[ -z "$_raw_url" ]]; then
    die "API response missing 'url' field. Response: ${_response:0:300}"
fi

# Validate it looks like a Broadcom ZIP URL
if ! echo "$_raw_url" | grep -qi "broadcom\.com.*\.zip"; then
    die "Unexpected URL format in API response: ${_raw_url}
  Expected a Broadcom ZIP download URL."
fi

# URL-encode spaces (Broadcom sometimes includes spaces in filenames)
latest_url="${_raw_url// /%20}"

# ── Extract version from URL ──
# Pattern: 007.3603.0000.0000 (three-digit.four-digit.four-digit.four-digit)
_raw_tag=$(echo "$_raw_url" | grep -oP '\d{3}\.\d{4}\.\d{4}\.\d{4}' || true)

if [[ -z "$_raw_tag" ]]; then
    die "Could not extract version number from URL: ${_raw_url}
  Expected a version like 007.3603.0000.0000 in the filename."
fi

latest_tag="$(normalize_tag "$_raw_tag")"

log "Latest: tag=${latest_tag}  url=${latest_url}"

# ── Compare with state ──
_state="$(load_state)"
_deployed_tag=$(echo "$_state" | jq -r '.tag // empty')
_deployed_url=$(echo "$_state" | jq -r '.url // empty')

log "Deployed: tag=${_deployed_tag:-none}"

all_releases="$(make_releases_json "${_deployed_tag:-$latest_tag}" "${_deployed_url:-$latest_url}")"

if [[ "$ALWAYS_BUILD" == "true" ]]; then
    has_new="true"
    log "ALWAYS_BUILD=true — forcing build"
elif [[ "$latest_tag" != "$_deployed_tag" ]]; then
    has_new="true"
    log "New version detected: ${_deployed_tag:-none} -> ${latest_tag}"
    save_state "$latest_tag" "$latest_url"
else
    has_new="false"
    log "Already built ${latest_tag}, nothing to do"
fi

if [[ "$has_new" == "true" ]]; then
    new_releases="$(make_releases_json "$latest_tag" "$latest_url")"
    all_releases="$new_releases"
else
    new_releases="[]"
fi

emit_output "has_new"      "$has_new"
emit_output "new_releases" "$new_releases"
emit_output "all_releases" "$all_releases"
emit_output "latest_tag"   "$latest_tag"
emit_output "latest_url"   "$latest_url"
log "Done — has_new=${has_new} latest_tag=${latest_tag}"
