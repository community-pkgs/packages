#!/usr/bin/env bash
# check-release.sh
#
# Determine whether a new upstream GitHub release should trigger a build.
#
# Required environment variables:
#   UPSTREAM_REPO     GitHub repository slug to check (e.g. valkey-io/valkey)
#
# Optional environment variables:
#   FORCE_TAG         Skip API call and use this tag directly (e.g. "9.0.3")
#   STATE_FILE        Path to the file storing the last processed release tag
#                     Default: last_release.txt
#   ALWAYS_BUILD      Set to "true" to output new_release=true unconditionally
#                     Default: false
#   GITHUB_TOKEN      Bearer token for GitHub API authentication
#   GITHUB_OUTPUT     Path to the GitHub Actions output file (set by runner)
#
# Outputs:
#   release_tag       Normalized release tag without leading "v" (e.g. "9.0.3")
#   major_version     Numeric major version (e.g. "9")
#   new_release       "true" or "false"
#
# When new_release=true and ALWAYS_BUILD is not "true", STATE_FILE is updated.
# The workflow is responsible for committing STATE_FILE back to the repository.

set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:?ERROR: UPSTREAM_REPO is required (e.g. valkey-io/valkey)}"
STATE_FILE="${STATE_FILE:-last_release.txt}"
ALWAYS_BUILD="${ALWAYS_BUILD:-false}"
FORCE_TAG="${FORCE_TAG:-}"

log() {
    printf '[check-release] %s\n' "$*" >&2
}

die() {
    printf '[check-release] ERROR: %s\n' "$*" >&2
    exit 1
}

# Write key=value to $GITHUB_OUTPUT when inside GitHub Actions, or stdout locally.
emit_output() {
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
    else
        printf '%s=%s\n' "$1" "$2"
    fi
}

if [[ -n "$FORCE_TAG" ]]; then
    RELEASE_TAG="${FORCE_TAG#v}"
    log "Using provided tag: ${RELEASE_TAG}"
else
    log "Fetching latest release for ${UPSTREAM_REPO} ..."

    _curl_args=(
        -sf --connect-timeout 15 --max-time 30
        -H "Accept: application/vnd.github+json"
        -H "X-GitHub-Api-Version: 2022-11-28"
    )
    [[ -n "${GITHUB_TOKEN:-}" ]] && _curl_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

    _api_url="https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest"
    log "  GET ${_api_url}"

    _response=$(
        curl "${_curl_args[@]}" "$_api_url" \
            || die "Failed to fetch latest release from GitHub API${GITHUB_TOKEN:+}$(
                [[ -z "${GITHUB_TOKEN:-}" ]] && printf ' (tip: set GITHUB_TOKEN to avoid rate limiting)'
            )"
    )

    RELEASE_TAG=$(printf '%s' "$_response" | jq -r '.tag_name // empty') \
        || die "jq failed parsing API response — is jq installed?"

    [[ -n "$RELEASE_TAG" ]] \
        || die "GitHub API returned no tag_name for ${UPSTREAM_REPO} (response may be empty or rate-limited)"

    RELEASE_TAG="${RELEASE_TAG#v}"
    log "Latest release tag: ${RELEASE_TAG}"
fi

MAJOR="${RELEASE_TAG%%.*}"

if [[ -z "$MAJOR" ]] || [[ "$MAJOR" =~ [^0-9] ]]; then
    die "Cannot derive numeric major version from tag: ${RELEASE_TAG}"
fi

log "Major version: ${MAJOR}"

if [[ "$ALWAYS_BUILD" == "true" ]]; then
    log "ALWAYS_BUILD=true — skipping state comparison"
    NEW_RELEASE="true"
else
    LAST_RELEASE="$(cat "$STATE_FILE" 2>/dev/null || echo none)"
    log "Last processed release: ${LAST_RELEASE}"

    if [[ "$RELEASE_TAG" != "$LAST_RELEASE" ]]; then
        NEW_RELEASE="true"
        # Update state file so concurrent or re-triggered runs do not duplicate the build.
        # The workflow commits this file back to the repository.
        printf '%s\n' "$RELEASE_TAG" > "$STATE_FILE"
        log "New release detected — updated ${STATE_FILE} to ${RELEASE_TAG}"
    else
        NEW_RELEASE="false"
        log "No new release (already processed ${RELEASE_TAG})"
    fi
fi

emit_output "release_tag"   "$RELEASE_TAG"
emit_output "major_version" "$MAJOR"
emit_output "new_release"   "$NEW_RELEASE"

log "Done — release_tag=${RELEASE_TAG} major_version=${MAJOR} new_release=${NEW_RELEASE}"
