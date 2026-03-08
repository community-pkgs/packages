#!/bin/bash
# gen-changelog-github.sh — generate debian/changelog from GitHub Releases API
#
# Works with any GitHub-hosted package, not just Valkey.
#
# Usage:
#   gen-changelog-github.sh PACKAGE REPO RELEASE_TAG MAINTAINER DISTRO [OUTPUT]
#
# Arguments:
#   PACKAGE         Debian source package name        (e.g. valkey)
#   REPO            GitHub repository slug            (e.g. valkey-io/valkey)
#   RELEASE_TAG     Upstream version to build         (e.g. 9.0.3)
#   MAINTAINER      Debian maintainer string          (e.g. "John Doe <john@example.com>")
#   DISTRO          Target distribution               (e.g. noble, trixie)
#   OUTPUT          Path to write changelog to        (default: debian/changelog)
#
# Environment:
#   GITHUB_TOKEN  Optional. Bearer token for GitHub API to avoid rate limiting.
#
# Dependencies: curl, jq, awk, GNU date (coreutils)

set -euo pipefail

PACKAGE="${1:?ERROR: PACKAGE is required (e.g. valkey)}"
REPO="${2:?ERROR: REPO is required (e.g. valkey-io/valkey)}"
RELEASE_TAG="${3:?ERROR: RELEASE_TAG is required (e.g. 9.0.3)}"
MAINTAINER="${4:?ERROR: MAINTAINER is required (e.g. \"John Doe <john@example.com>\")}"
DISTRO="${5:?ERROR: DISTRO is required (e.g. noble, trixie)}"
OUTPUT="${6:-debian/changelog}"

VERSION_SUFFIX="~${DISTRO}"

RELEASE_TAG="${RELEASE_TAG#v}"
MAJOR="${RELEASE_TAG%%.*}"

if [[ ! "$MAJOR" =~ ^[0-9]+$ ]]; then
    printf '[gen-changelog] ERROR: Cannot derive numeric MAJOR from RELEASE_TAG=%s\n' \
        "$RELEASE_TAG" >&2
    exit 1
fi

_CLEANUP_FILES=()
_cleanup() {
    if [[ ${#_CLEANUP_FILES[@]} -gt 0 ]]; then
        rm -f "${_CLEANUP_FILES[@]}"
    fi
}
trap _cleanup EXIT INT TERM

log() { printf '[gen-changelog] %s\n' "$*" >&2; }
die() { printf '[gen-changelog] ERROR: %s\n' "$*" >&2; exit 1; }

# Convert ISO 8601 → RFC 2822 using GNU date (always present in Debian/Ubuntu).
iso_to_rfc2822() {
    date -d "$1" -R
}

detect_urgency() {
    case "$1" in
        *'urgency SECURITY'*|*'urgency: SECURITY'*) printf 'critical' ;;
        *'urgency CRITICAL'*|*'urgency: CRITICAL'*) printf 'critical' ;;
        *'urgency HIGH'*|*'urgency: HIGH'*)          printf 'high'     ;;
        *'urgency MODERATE'*|*'urgency: MODERATE'*)  printf 'medium'   ;;
        *'urgency LOW'*|*'urgency: LOW'*)             printf 'low'      ;;
        *)                                            printf 'medium'   ;;
    esac
}

# Parse a GitHub markdown release body into Debian changelog bullet points.
#
# Rules:
#   - ^#{1,3} lines become section labels prefixed to subsequent bullets.
#   - Lines starting with "* " or "- " become changelog entries.
#   - Everything else is silently skipped.
#   - If no bullets are found, emits "  * Upstream release <tag>." as fallback.
parse_body() {
    local _body="$1"
    local _tag="$2"
    local _out="$3"

    awk -v tag="$_tag" '
        function trim(text) {
            sub(/^[[:space:]]+/, "", text)
            sub(/[[:space:]]+$/, "", text)
            return text
        }

        function print_bullet(text) {
            found = 1
            if (length(section) > 0)
                printf "  * [%s] %s\n", section, text
            else
                printf "  * %s\n", text
        }

        { gsub(/\r/, "") }

        /^#{1,3}[[:space:]]/ {
            section = $0
            sub(/^#{1,3}[[:space:]]+/, "", section)
            section = trim(section)
            next
        }

        /^[*-][[:space:]]/ {
            text = trim(substr($0, 3))
            if (length(text) == 0) next
            print_bullet(text)
            next
        }

        END {
            if (!found)
                printf "  * Upstream release %s.\n", tag
        }
    ' <<< "$_body" >> "$_out"
}

log "Fetching releases for ${REPO} ..."

_header_tmp=$(mktemp --tmpdir "gen-changelog-hdr.XXXXXX")
_pages_tmp=$(mktemp --tmpdir "gen-changelog-pages.XXXXXX")
_CLEANUP_FILES+=("$_header_tmp" "$_pages_tmp")

_curl_args=(
    -sf --connect-timeout 15 --max-time 30
    -D "$_header_tmp"
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
)
[[ -n "${GITHUB_TOKEN:-}" ]] && _curl_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    _curl_err="Failed to fetch releases from GitHub API"
else
    _curl_err="Failed to fetch releases from GitHub API (tip: set GITHUB_TOKEN to avoid rate limiting)"
fi

_next_url="https://api.github.com/repos/${REPO}/releases?per_page=100"

while [[ -n "$_next_url" ]]; do
    log "  GET ${_next_url}"

    curl "${_curl_args[@]}" "$_next_url" >> "$_pages_tmp" \
        || die "$_curl_err"

    printf '\n' >> "$_pages_tmp"

    _link_header=$(grep -i '^link:' "$_header_tmp" || true)
    if [[ "$_link_header" =~ \<([^>]+)\>[[:space:]]*\;[[:space:]]*rel=\"next\" ]]; then
        _next_url="${BASH_REMATCH[1]}"
    else
        _next_url=""
    fi
done

_all_releases=$(jq -cs 'add // []' "$_pages_tmp") \
    || die "jq failed merging pages — is jq installed?"

# Keep only stable releases for this major version, at or below RELEASE_TAG.
# semver() pads to 3 components so "9.0" compares correctly against "9.0.3".
_JQ_FILTER='
def semver(tag):
    (tag | ltrimstr("v") | split("."))
    | map(tonumber? // 0)
    | . + [0, 0, 0]
    | .[0:3];

[
    .[] | select(
        .prerelease == false and
        .draft      == false and
        ((.tag_name | ltrimstr("v")) | startswith($pfx)) and
        (semver(.tag_name) <= semver($cutoff))
    )
]
| sort_by(semver(.tag_name))
| reverse
| .[]
'

_filtered=$(jq -c --arg pfx "${MAJOR}." --arg cutoff "$RELEASE_TAG" "$_JQ_FILTER" <<< "$_all_releases") \
    || die "jq failed filtering releases"

if [[ -n "$_filtered" ]]; then
    mapfile -t _entries <<< "$_filtered"
else
    _entries=()
fi

[[ ${#_entries[@]} -gt 0 ]] \
    || die "No stable releases found for ${REPO} up to ${RELEASE_TAG}"

first_tag=$(jq -r '.tag_name | ltrimstr("v")' <<< "${_entries[0]}")
if [[ "$first_tag" != "$RELEASE_TAG" ]]; then
    die "RELEASE_TAG=${RELEASE_TAG} not found in GitHub releases for ${REPO} (latest matching: ${first_tag})"
fi

log "Found ${#_entries[@]} stable release(s) for ${PACKAGE} ${MAJOR}.x (up to ${RELEASE_TAG})"

: > "$OUTPUT"

for _entry in "${_entries[@]}"; do
    read -r _tag _pub <<< "$(jq -r '[(.tag_name | ltrimstr("v")), .published_at] | @tsv' <<< "$_entry")"
    _body=$(jq -r '.body' <<< "$_entry")

    _rfc=$(iso_to_rfc2822 "$_pub")
    _urgency=$(detect_urgency "$_body")

    log "  ${_tag}  urgency=${_urgency}  date=${_rfc}"

    printf '%s (%s-1%s) %s; urgency=%s\n\n' \
        "$PACKAGE" "$_tag" "$VERSION_SUFFIX" "$DISTRO" "$_urgency" >> "$OUTPUT"

    parse_body "$_body" "$_tag" "$OUTPUT"

    printf '\n -- %s  %s\n\n' "$MAINTAINER" "$_rfc" >> "$OUTPUT"
done

log "Done -> ${OUTPUT}"
