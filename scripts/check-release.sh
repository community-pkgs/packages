#!/usr/bin/env bash
# check-release.sh
#
# Determine whether new upstream GitHub releases should trigger a build.
#
# Two modes controlled by SINGLE_SUITE:
#   false (default) — multi-major: tracks the latest tag per major version.
#                     State file: {"8": "8.0.1", "9": "9.0.3"}
#   true            — single-suite: picks the single highest tag.
#                     State file: {"tag": "3.5.21"}
#
# Required:
#   UPSTREAM_REPO     e.g. valkey-io/valkey
#
# Optional:
#   SINGLE_SUITE      Default: true
#   SUITE_PREFIX      Prefix for suite discovery in multi mode. Default: <repo slug>
#   SUITE_NAME        Exact suite name for single mode. Default: <repo slug>
#   FORCE_TAG         Skip API call, build this tag exactly
#   STATE_FILE        JSON state file. Default: last_release.json / last_release_<slug>.json
#   ALWAYS_BUILD      Force has_new=true. Default: false
#   APT_BRANCH        Branch holding the APT repo. Default: apt
#   GITHUB_TOKEN      GitHub API token
#   GITHUB_OUTPUT     Set by GitHub Actions runner
#
# Outputs:
#   has_new           true / false
#   new_releases      [{"tag":"9.0.3","major":"9"}, …]  or  [{"tag":"3.5.21","major":""}]
#   all_releases      Same format, reflects current state of the apt branch
#   latest_tag        Highest tag found on GitHub

set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:?ERROR: UPSTREAM_REPO is required (e.g. valkey-io/valkey)}"

_slug="${UPSTREAM_REPO##*/}"

SINGLE_SUITE="${SINGLE_SUITE:-true}"
SUITE_PREFIX="${SUITE_PREFIX:-${_slug}}"
SUITE_NAME="${SUITE_NAME:-${_slug}}"
ALWAYS_BUILD="${ALWAYS_BUILD:-false}"
FORCE_TAG="${FORCE_TAG:-}"
APT_BRANCH="${APT_BRANCH:-apt}"

if [[ "$SINGLE_SUITE" == "true" ]]; then
    STATE_FILE="${STATE_FILE:-last_release_${_slug}.json}"
else
    STATE_FILE="${STATE_FILE:-last_release.json}"
fi

log()        { printf '[check-release] %s\n' "$*" >&2; }
die()        { printf '[check-release] ERROR: %s\n' "$*" >&2; exit 1; }

emit_output() {
    local key="$1" value="$2"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
    else
        printf '%s=%s\n' "$key" "$value"
    fi
}

major_from_tag() {
    local tag="${1#v}"
    local major="${tag%%.*}"
    if [[ -z "$major" ]] || [[ "$major" =~ [^0-9] ]]; then
        die "Cannot derive numeric major version from tag: $1"
    fi
    printf '%s' "$major"
}

_fetch_releases_json() {
    local curl_args=(
        -sf --connect-timeout 15 --max-time 30
        -H "Accept: application/vnd.github+json"
        -H "X-GitHub-Api-Version: 2022-11-28"
    )
    [[ -n "${GITHUB_TOKEN:-}" ]] && curl_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

    local api_url="https://api.github.com/repos/${UPSTREAM_REPO}/releases?per_page=50"
    log "GET $api_url"

    curl "${curl_args[@]}" "$api_url" \
        || die "Failed to fetch releases from GitHub API$(
            [[ -z "${GITHUB_TOKEN:-}" ]] && printf ' (tip: set GITHUB_TOKEN to avoid rate limiting)'
        )"
}

_apt_branch_fetched=false
_ensure_apt_branch() {
    if [[ "$_apt_branch_fetched" == "true" ]]; then return 0; fi
    if git fetch --depth=1 origin "${APT_BRANCH}" 2>/dev/null; then
        _apt_branch_fetched=true
        return 0
    fi
    log "apt branch '${APT_BRANCH}' not found — assuming no deployed packages"
    return 1
}

_read_suite_version() {
    local suite="$1"
    local components
    components="$(git ls-tree --name-only "origin/${APT_BRANCH}:dists/${suite}/" 2>/dev/null)" || true

    local packages_content=""
    for component in $components; do
        if packages_content="$(git show \
                "origin/${APT_BRANCH}:dists/${suite}/${component}/binary-amd64/Packages" \
                2>/dev/null)"; then
            break
        fi
    done

    [[ -z "$packages_content" ]] && return

    printf '%s\n' "$packages_content" \
        | grep '^Version:' | awk '{print $2}' \
        | sed 's/-[0-9][0-9]*~.*//' \
        | sort -V | tail -1
}

# ── Multi-major ──

fetch_latest_per_major() {
    local response
    response="$(_fetch_releases_json)"

    echo "$response" | jq -c '
      [ .[]
        | select(.prerelease == false and .draft == false)
        | .tag_name | ltrimstr("v")
      ]
      | map(. as $tag | { major: ($tag | split(".")[0]), tag: $tag })
      | group_by(.major)
      | map(sort_by(.tag | split(".") | map(tonumber)) | last)
    ' || die "jq failed while parsing GitHub API response"
}

fetch_deployed_per_major() {
    _ensure_apt_branch || { printf '[]'; return; }

    local codenames
    codenames="$(git ls-tree --name-only "origin/${APT_BRANCH}:dists/" 2>/dev/null \
        | grep -E "^${SUITE_PREFIX}[0-9]+$")" || true

    if [[ -z "$codenames" ]]; then
        log "No ${SUITE_PREFIX}N suites found in ${APT_BRANCH}:dists/"
        printf '[]'
        return
    fi

    local result='[]'
    while IFS= read -r codename; do
        local major="${codename#"${SUITE_PREFIX}"}"
        local version
        version="$(_read_suite_version "$codename")"

        if [[ -z "$version" ]]; then
            log "No version found for ${codename} — skipping"
            continue
        fi

        result="$(printf '%s\n' "$result" \
            | jq -c --arg m "$major" --arg t "$version" \
                '. + [{major: $m, tag: $t}]')"
        log "Deployed: ${codename} = ${version}"
    done <<< "$codenames"

    printf '%s\n' "$result" | jq -c 'sort_by(.major | tonumber) | reverse'
}

merge_releases() {
    local a="$1" b="$2"
    jq -cn \
        --argjson a "$a" \
        --argjson b "$b" \
        '$a + $b
         | group_by(.major)
         | map(sort_by(.tag | split(".") | map(tonumber)) | last)
         | sort_by(.major | tonumber) | reverse'
}

load_state_multi() {
    local legacy_file="${STATE_FILE%.json}.txt"

    if [[ -f "$STATE_FILE" ]]; then
        local content
        content="$(cat "$STATE_FILE")"
        if echo "$content" | jq -e 'type == "object"' > /dev/null 2>&1; then
            printf '%s' "$content"
            return
        fi
        log "WARNING: $STATE_FILE contains invalid JSON — treating as empty state"
    elif [[ -f "$legacy_file" ]]; then
        # Migrate legacy single-tag flat file to JSON object format.
        local legacy_tag
        legacy_tag="$(tr -d '[:space:]' < "$legacy_file")"
        if [[ -n "$legacy_tag" ]]; then
            local legacy_major
            legacy_major="$(major_from_tag "$legacy_tag")"
            log "Migrating $legacy_file ($legacy_tag) → $STATE_FILE"
            jq -n --arg m "$legacy_major" --arg t "$legacy_tag" '{($m): $t}'
            return
        fi
    fi

    printf '{}'
}

# ── Single-suite ──

fetch_latest_single() {
    local response
    response="$(_fetch_releases_json)"

    echo "$response" | jq -r '
        [ .[]
          | select(.prerelease == false and .draft == false)
          | .tag_name | ltrimstr("v")
        ]
        | map(. as $t | { tag: $t, parts: ($t | split(".") | map(tonumber? // 0)) })
        | sort_by(.parts)
        | last
        | .tag
    ' || die "jq failed while parsing GitHub API response"
}

fetch_deployed_single() {
    _ensure_apt_branch || { printf ''; return; }

    if ! git ls-tree --name-only "origin/${APT_BRANCH}:dists/" 2>/dev/null \
            | grep -qxF "${SUITE_NAME}"; then
        log "Suite '${SUITE_NAME}' not found in ${APT_BRANCH}:dists/"
        printf ''
        return
    fi

    local version
    version="$(_read_suite_version "$SUITE_NAME")"

    printf '%s' "$version"
    [[ -n "$version" ]] && log "Deployed: ${SUITE_NAME} = ${version}"
}

load_state_single() {
    if [[ -f "$STATE_FILE" ]]; then
        local content
        content="$(cat "$STATE_FILE")"
        if echo "$content" | jq -e 'type == "object"' > /dev/null 2>&1; then
            echo "$content" | jq -r '.tag // empty'
            return
        fi
        log "WARNING: $STATE_FILE contains invalid JSON — treating as empty state"
    fi
    printf ''
}

save_state_single() {
    jq -n --arg t "$1" '{"tag": $t}' > "$STATE_FILE"
    log "Saved $STATE_FILE: tag=$1"
}

make_single_releases_json() {
    printf '[{"tag":"%s","major":""}]' "$1"
}

# ── FORCE_TAG ──

if [[ -n "$FORCE_TAG" ]]; then
    FORCE_TAG="${FORCE_TAG#v}"
    log "Using FORCE_TAG: ${FORCE_TAG}"

    if [[ "$SINGLE_SUITE" == "true" ]]; then
        new_releases="$(make_single_releases_json "$FORCE_TAG")"
        all_releases="$new_releases"
        latest_tag="$FORCE_TAG"
    else
        MAJOR="$(major_from_tag "$FORCE_TAG")"
        log "major=${MAJOR}"
        new_releases="[{\"tag\":\"${FORCE_TAG}\",\"major\":\"${MAJOR}\"}]"
        deployed="$(fetch_deployed_per_major)"
        all_releases="$(merge_releases "$deployed" "$new_releases")"
        latest_tag="$(printf '%s\n' "$all_releases" | jq -r \
            '[.[].tag] | sort_by(split(".") | map(tonumber)) | last')"
    fi

    emit_output "has_new"      "true"
    emit_output "new_releases" "$new_releases"
    emit_output "all_releases" "$all_releases"
    emit_output "latest_tag"   "$latest_tag"
    log "Done — has_new=true new_releases=${new_releases} all_releases=${all_releases} latest_tag=${latest_tag}"
    exit 0
fi

# ── Single-suite flow ──

if [[ "$SINGLE_SUITE" == "true" ]]; then
    latest_tag="$(fetch_latest_single)"

    if [[ -z "$latest_tag" ]]; then
        log "No qualifying releases found for ${UPSTREAM_REPO}"
        emit_output "has_new"      "false"
        emit_output "new_releases" "[]"
        emit_output "all_releases" "[]"
        emit_output "latest_tag"   ""
        exit 0
    fi

    log "Latest tag: ${latest_tag}"

    deployed_tag="$(fetch_deployed_single)"
    all_releases="$(make_single_releases_json "$latest_tag")"

    if [[ "$ALWAYS_BUILD" == "true" ]]; then
        has_new="true"
        log "ALWAYS_BUILD=true — forcing build"
    else
        state_tag="$(load_state_single)"
        log "State file tag: '${state_tag}'"

        if [[ "$latest_tag" != "$state_tag" ]]; then
            has_new="true"
            save_state_single "$latest_tag"
        else
            has_new="false"
            log "Already built ${latest_tag}, nothing to do"
        fi
    fi

    if [[ "$has_new" == "true" ]]; then
        new_releases="$(make_single_releases_json "$latest_tag")"
    else
        new_releases="[]"
        if [[ -n "$deployed_tag" ]]; then
            all_releases="$(make_single_releases_json "$deployed_tag")"
        else
            all_releases="[]"
        fi
    fi

    emit_output "has_new"      "$has_new"
    emit_output "new_releases" "$new_releases"
    emit_output "all_releases" "$all_releases"
    emit_output "latest_tag"   "$latest_tag"
    log "Done — has_new=${has_new} new_releases=${new_releases} all_releases=${all_releases} latest_tag=${latest_tag}"
    exit 0
fi

# ── Multi-major flow ──

latest_per_major_json="$(fetch_latest_per_major)"
log "Latest releases per major: $latest_per_major_json"

release_count="$(echo "$latest_per_major_json" | jq 'length')"
if [[ "$release_count" -eq 0 ]]; then
    log "No qualifying releases found for ${UPSTREAM_REPO}"
    emit_output "has_new"      "false"
    emit_output "new_releases" "[]"
    emit_output "all_releases" "[]"
    emit_output "latest_tag"   ""
    exit 0
fi

latest_tag="$(echo "$latest_per_major_json" | jq -r \
    '[.[].tag] | sort_by(split(".") | map(tonumber)) | last')"
log "Overall latest tag: $latest_tag"

deployed_per_major="$(fetch_deployed_per_major)"
log "Deployed per major: ${deployed_per_major}"

if [[ "$ALWAYS_BUILD" == "true" ]]; then
    deployed_count="$(printf '%s\n' "$deployed_per_major" | jq 'length')"

    if [[ "$deployed_count" -gt 0 ]]; then
        # Restrict to already-deployed majors to avoid accidentally seeding a
        # brand-new major that appeared on GitHub but was never part of this repo.
        log "ALWAYS_BUILD=true — rebuilding ${deployed_count} deployed major(s)"
        new_releases="$(
            printf '%s\n' "$latest_per_major_json" | jq -c \
                --argjson deployed "$deployed_per_major" \
                '[.[] | . as $r
                  | select(($deployed | map(.major) | index($r.major)) != null)
                  | {tag: .tag, major: .major}]'
        )"
    else
        log "ALWAYS_BUILD=true — apt branch empty, seeding all majors from GitHub"
        new_releases="$(echo "$latest_per_major_json" | jq -c '[.[] | {tag: .tag, major: .major}]')"
    fi

else
    state="$(load_state_multi)"
    log "Current state: $state"

    new_releases="$(
        echo "$latest_per_major_json" | jq -c \
            --argjson state "$state" \
            '[.[] | select(.tag != ($state[.major] // "")) | {tag: .tag, major: .major}]'
    )"

    new_count="$(echo "$new_releases" | jq 'length')"
    if [[ "$new_count" -gt 0 ]]; then
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

all_releases="$(merge_releases "$deployed_per_major" "$new_releases")"

emit_output "has_new"      "$has_new"
emit_output "new_releases" "$new_releases"
emit_output "all_releases" "$all_releases"
emit_output "latest_tag"   "$latest_tag"
log "Done — has_new=${has_new} new_releases=${new_releases} all_releases=${all_releases} latest_tag=${latest_tag}"
