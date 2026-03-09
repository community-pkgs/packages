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
#   FORCE_TAG         Skip upstream API call and build exactly this tag (e.g. "9.0.3")
#   STATE_FILE        Path to the JSON file storing last processed tag per major
#                     Default: last_release.json
#                     Format:  {"8": "8.0.1", "9": "9.0.3"}
#   ALWAYS_BUILD      Set to "true" to output has_new=true unconditionally
#                     Default: false
#   APT_BRANCH        Name of the git branch that holds the APT repository
#                     Default: apt
#   GITHUB_TOKEN      Bearer token for GitHub API authentication
#   GITHUB_OUTPUT     Path to the GitHub Actions output file (set by runner)
#
# Outputs:
#   has_new           "true" or "false"
#   new_releases      JSON array of releases to build this run, e.g.:
#                     [{"tag":"9.0.3","major":"9"},{"tag":"8.1.0","major":"8"}]
#                     Empty array "[]" when has_new=false
#   all_releases      JSON array reflecting every major version currently present
#                     in the APT repository (apt branch), merged with new_releases
#                     so the entry being deployed now is always included.
#                     Used by index.html to render one tab per deployed major.
#                     e.g. [{"tag":"9.0.3","major":"9"},{"tag":"8.1.0","major":"8"}]
#   latest_tag        Highest version tag found across all majors on GitHub
#                     (for display / README purposes)
#
# State file (last_release.json):
#   Used ONLY for change-detection in the scheduled path — to know which majors
#   have already been built so we don't rebuild them unnecessarily.
#   It is NOT used as the source of truth for all_releases; that comes from the
#   actual contents of the APT repository (apt branch).
#
#   When has_new=true and ALWAYS_BUILD is not "true" and FORCE_TAG is not set,
#   STATE_FILE is updated with the new tags per major.  The workflow is
#   responsible for committing STATE_FILE back to the repository.
#
#   Migration: if STATE_FILE does not exist but a legacy last_release.txt does,
#   the single tag in that file is automatically migrated to JSON format.

set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:?ERROR: UPSTREAM_REPO is required (e.g. valkey-io/valkey)}"
STATE_FILE="${STATE_FILE:-last_release.json}"
ALWAYS_BUILD="${ALWAYS_BUILD:-false}"
FORCE_TAG="${FORCE_TAG:-}"
APT_BRANCH="${APT_BRANCH:-apt}"

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
            || die "Failed to fetch releases from GitHub API$(
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

# Read the highest deployed version per major directly from the APT repository
# stored in the apt branch.  Returns a JSON array sorted by major descending:
#   [{"major":"9","tag":"9.0.3"},{"major":"8","tag":"8.1.6"},{"major":"7","tag":"7.2.12"}]
#
# Strategy:
#   1. Shallow-fetch the apt branch so git-show can access its tree without a
#      full clone.  Safe to call even when the branch doesn't exist yet.
#   2. List dists/ in the apt branch to discover which valkeyN suites are present.
#   3. For each suite read one representative Packages file and extract Version.
#   4. Strip the Debian revision + distro suffix (e.g. "8.1.6-1~noble" → "8.1.6").
#
# Returns an empty array [] gracefully when:
#   - the apt branch does not exist yet (first ever build)
#   - the fetch fails for any reason
#   - dists/ contains no matching valkey suites
fetch_deployed_per_major() {
    # Shallow-fetch the apt branch.  --depth=1 is enough to read the tree.
    # Redirect stderr so a missing branch doesn't pollute CI logs with errors.
    if ! git fetch --depth=1 origin "${APT_BRANCH}" 2>/dev/null; then
        log "apt branch '${APT_BRANCH}' not found or fetch failed — assuming no deployed packages"
        printf '[]'
        return
    fi

    # Discover which valkeyN suites exist by listing dists/ in the apt branch.
    # This works both with the old reprepro layout (conf/distributions) and the
    # new dpkg-scanpackages layout where conf/ no longer exists.
    local codenames
    codenames="$(git ls-tree --name-only "origin/${APT_BRANCH}:dists/" 2>/dev/null \
        | grep -E '^valkey[0-9]+$')" || true

    if [[ -z "$codenames" ]]; then
        log "No valkey suites found in ${APT_BRANCH}:dists/"
        printf '[]'
        return
    fi

    local result='[]'

    while IFS= read -r codename; do
        local major="${codename#valkey}"

        # Read a representative Packages file.  noble/amd64 is used as the
        # canonical sample — every component/arch carries the same upstream
        # version number.  Fall back silently if that particular file is absent.
        local packages_content
        if ! packages_content="$(git show \
                "origin/${APT_BRANCH}:dists/${codename}/noble/binary-amd64/Packages" \
                2>/dev/null)"; then
            log "Packages file not found for ${codename}/noble/amd64 — skipping"
            continue
        fi

        # Version field looks like "8.1.6-1~noble".
        # Strip "-<revision>~<distro>" to recover the bare upstream tag.
        # With multi-version Packages files, sort all versions and take the
        # highest so the scheduler correctly sees the latest deployed release.
        local version
        version="$(printf '%s\n' "$packages_content" \
            | grep '^Version:' | awk '{print $2}' \
            | sed 's/-[0-9][0-9]*~.*//' \
            | sort -V | tail -1)"

        if [[ -z "$version" ]]; then
            log "Could not parse Version from Packages for ${codename} — skipping"
            continue
        fi

        result="$(printf '%s\n' "$result" \
            | jq -c --arg m "$major" --arg t "$version" \
                '. + [{major: $m, tag: $t}]')"
        log "Deployed: valkey${major} = ${version}"
    done <<< "$codenames"

    printf '%s\n' "$result" | jq -c 'sort_by(.major | tonumber) | reverse'
}

# Merge two JSON arrays of {major, tag} objects, keeping the highest semver tag
# per major and returning the result sorted by major descending.
merge_releases() {
    local a="$1"   # JSON array (base, e.g. deployed)
    local b="$2"   # JSON array (overlay, e.g. new_releases)

    jq -cn \
        --argjson a "$a" \
        --argjson b "$b" \
        '$a + $b
         | group_by(.major)
         | map(sort_by(.tag | split(".") | map(tonumber)) | last)
         | sort_by(.major | tonumber) | reverse'
}

# ── FORCE_TAG fast path ────────────────────────────────────────────────────────

if [[ -n "$FORCE_TAG" ]]; then
    FORCE_TAG="${FORCE_TAG#v}"
    MAJOR="$(major_from_tag "$FORCE_TAG")"
    log "Using provided FORCE_TAG: ${FORCE_TAG} (major=${MAJOR})"

    new_releases="[{\"tag\":\"${FORCE_TAG}\",\"major\":\"${MAJOR}\"}]"

    # all_releases: what is (or will be) in the APT repository.
    # Read the apt branch for the real deployed state, then merge the forced
    # entry so the version being built now is always reflected.
    deployed="$(fetch_deployed_per_major)"
    all_releases="$(merge_releases "$deployed" "$new_releases")"

    latest_tag="$(printf '%s\n' "$all_releases" | jq -r '
        [.[].tag] | sort_by(split(".") | map(tonumber)) | last
    ')"

    emit_output "has_new"      "true"
    emit_output "new_releases" "$new_releases"
    emit_output "all_releases" "$all_releases"
    emit_output "latest_tag"   "$latest_tag"
    log "Done — has_new=true new_releases=${new_releases} all_releases=${all_releases} latest_tag=${latest_tag}"
    exit 0
fi

# ── Fetch latest per major from GitHub ────────────────────────────────────────

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

# ── Read deployed state from apt branch ───────────────────────────────────────
#
# This is the single authoritative source for all_releases (index.html tabs).
# It is also used in ALWAYS_BUILD mode to restrict rebuilds to majors that are
# already present in the repository.

deployed_per_major="$(fetch_deployed_per_major)"
log "Deployed per major: ${deployed_per_major}"

# ── Determine new_releases ────────────────────────────────────────────────────

if [[ "$ALWAYS_BUILD" == "true" ]]; then
    deployed_count="$(printf '%s\n' "$deployed_per_major" | jq 'length')"

    if [[ "$deployed_count" -gt 0 ]]; then
        # Rebuild only majors that are already present in the APT repository.
        # This prevents accidentally building a brand-new major that appeared on
        # GitHub but was never part of this repo.
        log "ALWAYS_BUILD=true — rebuilding ${deployed_count} deployed major(s)"
        new_releases="$(
            printf '%s\n' "$latest_per_major_json" | jq -c \
                --argjson deployed "$deployed_per_major" \
                '[.[] | . as $r
                  | select(($deployed | map(.major) | index($r.major)) != null)
                  | {tag: .tag, major: .major}]'
        )"
    else
        # No apt branch yet — seed the repo with all current GitHub releases.
        log "ALWAYS_BUILD=true — apt branch empty, seeding all majors from GitHub"
        new_releases="$(echo "$latest_per_major_json" | jq -c '[.[] | {tag: .tag, major: .major}]')"
    fi

else
    # Scheduled path: only build majors whose latest GitHub tag differs from
    # what was last recorded in STATE_FILE.
    state="$(load_state)"
    log "Current state: $state"

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

# ── Compute all_releases ──────────────────────────────────────────────────────
#
# Source of truth: what is actually in the APT repository (apt branch), merged
# with new_releases so the version(s) being deployed now are always included
# even though they haven't landed in the apt branch yet.

all_releases="$(merge_releases "$deployed_per_major" "$new_releases")"

emit_output "has_new"      "$has_new"
emit_output "new_releases" "$new_releases"
emit_output "all_releases" "$all_releases"
emit_output "latest_tag"   "$latest_tag"
log "Done — has_new=${has_new} new_releases=${new_releases} all_releases=${all_releases} latest_tag=${latest_tag}"
