#!/usr/bin/env bash
# check-release.sh
#
# Determine whether any new upstream GitHub releases should trigger a build.
# Unlike the previous version which only checked /releases/latest, this script
# checks all recent releases and finds the latest tag per major version.
# This correctly handles the case where multiple major versions are released
# on the same day (e.g. 8.1.0 and 9.0.3 released simultaneously).
#
# Required environment variables:
#   UPSTREAM_REPO     GitHub repository slug to check (e.g. valkey-io/valkey)
#
# Optional environment variables:
#   FORCE_TAG         Skip API call and use this tag directly (e.g. "9.0.3")
#   STATE_FILE        Path to the JSON file storing last processed tag per major
#                     Default: last_release.json
#                     Format:  {"8": "8.0.1", "9": "9.0.3"}
#   ALWAYS_BUILD      Set to "true" to output has_new=true unconditionally
#                     Default: false
#   GITHUB_TOKEN      Bearer token for GitHub API authentication
#   GITHUB_OUTPUT     Path to the GitHub Actions output file (set by runner)
#
# Outputs:
#   has_new           "true" or "false"
#   new_releases      JSON array of new releases, e.g.:
#                     [{"tag":"9.0.3","major":"9"},{"tag":"8.1.0","major":"8"}]
#                     Empty array "[]" when has_new=false
#   all_releases      JSON array of ALL currently active major versions (not just new ones).
#                     Use this for index.html so it always shows every maintained major,
#                     even when only one major had a new release this run.
#                     e.g. [{"tag":"9.0.3","major":"9"},{"tag":"8.1.0","major":"8"}]
#   latest_tag        Highest version tag found across all majors (for display/README)
#
# State file:
#   When has_new=true and ALWAYS_BUILD is not "true" and FORCE_TAG is not set,
#   STATE_FILE is updated with the new tags per major. The workflow is responsible
#   for committing STATE_FILE back to the repository.
#
#   Migration: if STATE_FILE does not exist but a legacy last_release.txt does,
#   the single tag in that file is automatically migrated to JSON format.

set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:?ERROR: UPSTREAM_REPO is required (e.g. valkey-io/valkey)}"
STATE_FILE="${STATE_FILE:-last_release.json}"
ALWAYS_BUILD="${ALWAYS_BUILD:-false}"
FORCE_TAG="${FORCE_TAG:-}"

log() {
    printf '[check-release] %s\n' "$*" >&2
}

die() {
    printf '[check-release] ERROR: %s\n' "$*" >&2
    exit 1
}

# Write a single-line key=value to $GITHUB_OUTPUT (or stdout when running locally).
emit_output() {
    local key="$1" value="$2"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
    else
        printf '%s=%s\n' "$key" "$value"
    fi
}

# ── Helpers ────────────────────────────────────────────────────────────────────

# Derive the numeric major version from a semver tag (strips leading "v").
major_from_tag() {
    local tag="${1#v}"
    local major="${tag%%.*}"

    if [[ -z "$major" ]] || [[ "$major" =~ [^0-9] ]]; then
        die "Cannot derive numeric major version from tag: $1"
    fi

    printf '%s' "$major"
}

# Load the state JSON object.  Falls back to migrating a legacy last_release.txt
# if it exists, or returns an empty object {} when neither file is present.
load_state() {
    local legacy_file="${STATE_FILE%.json}.txt"

    if [[ -f "$STATE_FILE" ]]; then
        local content
        content="$(cat "$STATE_FILE")"
        # Validate it is a JSON object; fall back to empty on corruption.
        if echo "$content" | jq -e 'type == "object"' > /dev/null 2>&1; then
            printf '%s' "$content"
            return
        fi
        log "WARNING: $STATE_FILE contains invalid JSON — treating as empty state"
    elif [[ -f "$legacy_file" ]]; then
        local legacy_tag
        legacy_tag="$(tr -d '[:space:]' < "$legacy_file")"
        if [[ -n "$legacy_tag" ]]; then
            local legacy_major
            legacy_major="$(major_from_tag "$legacy_tag")"
            log "Migrating legacy state file $legacy_file ($legacy_tag) → $STATE_FILE"
            jq -n --arg m "$legacy_major" --arg t "$legacy_tag" '{($m): $t}'
            return
        fi
    fi

    printf '{}'
}

# Fetch JSON array of {major, tag} objects — one entry per major version,
# representing the highest semver non-prerelease non-draft tag for that major.
fetch_latest_per_major() {
    local curl_args=(
        -sf --connect-timeout 15 --max-time 30
        -H "Accept: application/vnd.github+json"
        -H "X-GitHub-Api-Version: 2022-11-28"
    )
    [[ -n "${GITHUB_TOKEN:-}" ]] && curl_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

    # Fetch up to 50 recent releases.  For projects like Valkey that maintain
    # multiple concurrent major release lines this is more than sufficient.
    local api_url="https://api.github.com/repos/${UPSTREAM_REPO}/releases?per_page=50"
    log "GET $api_url"

    local response
    response=$(
        curl "${curl_args[@]}" "$api_url" \
            || die "Failed to fetch releases from GitHub API${GITHUB_TOKEN:+}$(
                [[ -z "${GITHUB_TOKEN:-}" ]] && printf ' (tip: set GITHUB_TOKEN to avoid rate limiting)'
            )"
    )

    # For each non-prerelease, non-draft release:
    #   1. Strip leading "v" from tag_name.
    #   2. Group by the first semver component (major).
    #   3. Within each group, sort by version components numerically and take the last (highest).
    #
    # jq's sort_by is stable and operates on arrays, so map(tonumber) on each
    # dot-separated part gives correct numeric ordering (9.0.10 > 9.0.9).
    echo "$response" | jq -c '
      [ .[]
        | select(.prerelease == false and .draft == false)
        | .tag_name | ltrimstr("v")
      ]
      | map(
          . as $tag |
          { major: ($tag | split(".")[0]), tag: $tag }
        )
      | group_by(.major)
      | map(
          sort_by(.tag | split(".") | map(tonumber))
          | last
        )
    ' || die "jq failed while parsing GitHub API response — is jq installed and is the response valid JSON?"
}

# ── FORCE_TAG fast path ────────────────────────────────────────────────────────

if [[ -n "$FORCE_TAG" ]]; then
    FORCE_TAG="${FORCE_TAG#v}"
    MAJOR="$(major_from_tag "$FORCE_TAG")"
    log "Using provided FORCE_TAG: ${FORCE_TAG} (major=${MAJOR})"

    new_releases="[{\"tag\":\"${FORCE_TAG}\",\"major\":\"${MAJOR}\"}]"

    # Build all_releases from the deployed-state file merged with the forced tag.
    # This ensures index.html shows only versions that are actually present in the
    # APT repository (tracked by STATE_FILE), not every tag that exists on GitHub.
    state="$(load_state)"
    all_releases="$(
        jq -cn \
            --argjson state "$state" \
            --arg major "$MAJOR" \
            --arg tag "$FORCE_TAG" \
            '($state | to_entries | map({major: .key, tag: .value}))
             + [{major: $major, tag: $tag}]
             | group_by(.major)
             | map(sort_by(.tag | split(".") | map(tonumber)) | last)
             | sort_by(.major | tonumber) | reverse'
    )"

    # Overall highest version tag across all known deployed majors.
    latest_tag="$(echo "$all_releases" | jq -r '
        [.[].tag]
        | sort_by(split(".") | map(tonumber))
        | last
    ')"

    emit_output "has_new"      "true"
    emit_output "new_releases" "$new_releases"
    emit_output "all_releases" "$all_releases"
    emit_output "latest_tag"   "$latest_tag"
    log "Done — has_new=true new_releases=${new_releases} all_releases=${all_releases} latest_tag=${latest_tag}"
    exit 0
fi

# ── Fetch latest per major ─────────────────────────────────────────────────────

latest_per_major_json="$(fetch_latest_per_major)"
log "Latest releases per major: $latest_per_major_json"

# Guard against an empty result (e.g. all releases are pre-releases/drafts).
release_count="$(echo "$latest_per_major_json" | jq 'length')"
if [[ "$release_count" -eq 0 ]]; then
    log "No qualifying releases found for ${UPSTREAM_REPO}"
    emit_output "has_new"      "false"
    emit_output "new_releases" "[]"
    emit_output "all_releases" "[]"
    emit_output "latest_tag"   ""
    exit 0
fi

# Overall highest version tag (for README / display purposes).
latest_tag="$(echo "$latest_per_major_json" | jq -r '
    [.[].tag]
    | sort_by(split(".") | map(tonumber))
    | last
')"
log "Overall latest tag: $latest_tag"

# ── Compare with state ────────────────────────────────────────────────────────

state="$(load_state)"
log "Current state: $state"

if [[ "$ALWAYS_BUILD" == "true" ]]; then
    # Rebuild only majors that are already tracked in the state file (i.e. have
    # previously been built and deployed).  This prevents accidentally building
    # a brand-new major that was never part of the repository just because it
    # appeared on GitHub.  If the state is empty (very first run) we fall back
    # to all latest versions from GitHub so the repo can be seeded.
    state_count="$(echo "$state" | jq 'length')"
    if [[ "$state_count" -gt 0 ]]; then
        log "ALWAYS_BUILD=true — rebuilding ${state_count} state-tracked major(s)"
        new_releases="$(
            echo "$latest_per_major_json" | jq -c \
                --argjson state "$state" \
                '[.[] | select($state[.major] != null) | {tag: .tag, major: .major}]'
        )"
    else
        log "ALWAYS_BUILD=true — state is empty, seeding from GitHub"
        new_releases="$(echo "$latest_per_major_json" | jq -c '[.[] | {tag: .tag, major: .major}]')"
    fi
else
    # Select only those majors whose latest tag differs from the stored tag.
    new_releases="$(
        echo "$latest_per_major_json" | jq -c \
            --argjson state "$state" \
            '[.[] | select(.tag != ($state[.major] // "")) | {tag: .tag, major: .major}]'
    )"

    new_count="$(echo "$new_releases" | jq 'length')"
    if [[ "$new_count" -gt 0 ]]; then
        # Merge new tags into the existing state object and persist.
        updated_state="$(
            echo "$new_releases" | jq -c \
                --argjson state "$state" \
                'reduce .[] as $r ($state; .[$r.major] = $r.tag)'
        )"
        printf '%s\n' "$updated_state" > "$STATE_FILE"
        log "Updated $STATE_FILE: $updated_state"
    else
        log "No new releases detected"
    fi
fi

has_new="false"
[[ "$(echo "$new_releases" | jq 'length')" -gt 0 ]] && has_new="true"

# all_releases: versions actually present in the APT repository.
# Derived from the state (previously deployed) merged with new_releases (being
# deployed now), so index.html never lists versions that were never built.
all_releases="$(
    jq -cn \
        --argjson state "$state" \
        --argjson new "$new_releases" \
        '($state | to_entries | map({major: .key, tag: .value})) + $new
         | group_by(.major)
         | map(sort_by(.tag | split(".") | map(tonumber)) | last)
         | sort_by(.major | tonumber) | reverse'
)"

emit_output "has_new"      "$has_new"
emit_output "new_releases" "$new_releases"
emit_output "all_releases" "$all_releases"
emit_output "latest_tag"   "$latest_tag"
log "Done — has_new=${has_new} new_releases=${new_releases} all_releases=${all_releases} latest_tag=${latest_tag}"
