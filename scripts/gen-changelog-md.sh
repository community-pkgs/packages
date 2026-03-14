#!/bin/bash
# gen-changelog-md.sh — generate debian/changelog from per-minor Markdown CHANGELOG files.
#
# For projects that maintain changelogs as versioned Markdown files organized
# by minor version (e.g. etcd's CHANGELOG/CHANGELOG-3.5.md).
#
# Usage:
#   gen-changelog-md.sh PACKAGE REPO RELEASE_TAG MAINTAINER DISTRO [OUTPUT]
#
# Arguments:
#   PACKAGE         Debian source package name        (e.g. etcd)
#   REPO            GitHub repository slug            (e.g. etcd-io/etcd)
#   RELEASE_TAG     Upstream version to build         (e.g. 3.5.21)
#   MAINTAINER      Debian maintainer string          (e.g. "Name <email>")
#   DISTRO          Target distribution               (e.g. noble, trixie)
#   OUTPUT          Path to write changelog to        (default: debian/changelog)
#
# Environment:
#   CHANGELOG_URL_PATTERN   URL template with __MAJOR__ and __MINOR__ placeholders.
#                           Default: https://raw.githubusercontent.com/REPO/main/CHANGELOG/CHANGELOG-__MAJOR__.__MINOR__.md
#   CHANGELOG_START_MINOR   Lowest minor version to fetch. Default: 0
#   GITHUB_TOKEN            Optional. Bearer token for GitHub raw content.

set -euo pipefail

PACKAGE="${1:?ERROR: PACKAGE is required (e.g. etcd)}"
REPO="${2:?ERROR: REPO is required (e.g. etcd-io/etcd)}"
RELEASE_TAG="${3:?ERROR: RELEASE_TAG is required (e.g. 3.5.21)}"
MAINTAINER="${4:?ERROR: MAINTAINER is required}"
DISTRO="${5:?ERROR: DISTRO is required (e.g. noble, trixie)}"
OUTPUT="${6:-debian/changelog}"

RELEASE_TAG="${RELEASE_TAG#v}"
MAJOR="${RELEASE_TAG%%.*}"
MINOR="${RELEASE_TAG#*.}"; MINOR="${MINOR%%.*}"

[[ "$MAJOR" =~ ^[0-9]+$ && "$MINOR" =~ ^[0-9]+$ ]] \
    || { printf '[gen-changelog-md] ERROR: Cannot parse RELEASE_TAG=%s\n' "$RELEASE_TAG" >&2; exit 1; }

: "${CHANGELOG_URL_PATTERN:=https://raw.githubusercontent.com/${REPO}/main/CHANGELOG/CHANGELOG-__MAJOR__.__MINOR__.md}"
: "${CHANGELOG_START_MINOR:=0}"

log() { printf '[gen-changelog-md] %s\n' "$*" >&2; }
die() { printf '[gen-changelog-md] ERROR: %s\n' "$*" >&2; exit 1; }

_curl_args=(-fsSL --connect-timeout 15 --max-time 30)
[[ -n "${GITHUB_TOKEN:-}" ]] && _curl_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

# Process from current minor downwards — each file is newest-first internally.
_combined=""
for m in $(seq "$MINOR" -1 "$CHANGELOG_START_MINOR"); do
    url=$(printf '%s' "$CHANGELOG_URL_PATTERN" | sed "s/__MAJOR__/$MAJOR/g; s/__MINOR__/$m/g")
    log "Fetching ${url}"
    content=$(curl "${_curl_args[@]}" "$url" 2>/dev/null) || {
        log "WARNING: ${url} not found, skipping"
        continue
    }
    _combined+=$'\n'"$content"
done

[[ -n "$_combined" ]] || die "No changelog content fetched"

: > "$OUTPUT"

awk \
    -v pkg="$PACKAGE" \
    -v distro="$DISTRO" \
    -v maintainer="$MAINTAINER" \
    -v cutoff="$RELEASE_TAG" \
    -v output="$OUTPUT" \
'
function semver_cmp(a, b,    pa, pb, i, va, vb) {
    split(a, pa, ".")
    split(b, pb, ".")
    for (i = 1; i <= 3; i++) {
        va = pa[i] + 0; vb = pb[i] + 0
        if (va < vb) return -1
        if (va > vb) return  1
    }
    return 0
}

function strip_md(s,    out, pre, ltext, rest) {
    out = s
    while (match(out, /\[[^\]]+\]\([^)]*\)/)) {
        pre   = substr(out, 1, RSTART - 1)
        ltext = substr(out, RSTART + 1, RLENGTH - 1)
        sub(/\].*/, "", ltext)
        rest  = substr(out, RSTART + RLENGTH)
        out   = pre ltext rest
    }
    gsub(/[`*]/, "", out)
    sub(/^[[:space:]]+/, "", out)
    sub(/[[:space:]]+$/, "", out)
    return out
}

function flush(    i, cmd, rfc) {
    if (cur_tag == "" || date_str == "" || date_str == "TBC") return
    if (semver_cmp(cur_tag, cutoff) > 0) return

    printf "%s (%s-1~%s) %s; urgency=medium\n\n", pkg, cur_tag, distro, distro > output

    if (nbullets == 0) {
        printf "  * Upstream release %s.\n", cur_tag > output
    } else {
        for (i = 1; i <= nbullets; i++)
            printf "  * %s\n", bullets[i] > output
    }

    cmd = "date -d " date_str " -R 2>/dev/null"
    cmd | getline rfc
    close(cmd)
    if (rfc == "") rfc = "Thu, 01 Jan 1970 00:00:00 +0000"

    printf "\n -- %s  %s\n\n", maintainer, rfc > output
    entry_count++
}

BEGIN { cur_tag = ""; date_str = ""; section = ""; nbullets = 0; entry_count = 0 }

# Supports both formats:
#   ## v3.5.21 (2025-03-27)
#   ## [v3.0.16](url) (2016-11-13)
/^## (\[)?v[0-9]+\.[0-9]+\.[0-9]/ {
    flush()
    cur_tag = $0
    sub(/^.*v/, "", cur_tag); sub(/[^0-9.].*/, "", cur_tag)
    date_str = ""; section = ""; nbullets = 0; delete bullets
    if (match($0, /\(([0-9]{4}-[0-9]{2}-[0-9]{2})\)/))
        date_str = substr($0, RSTART + 1, RLENGTH - 2)
    else if (match($0, /\(TBC\)/))
        date_str = "TBC"
    next
}

/^### / {
    section = substr($0, 5)
    sub(/^[[:space:]]+/, "", section); sub(/[[:space:]]+$/, "", section)
    next
}

/^[[:space:]]*[-*][[:space:]]/ {
    if (cur_tag == "") next
    text = $0
    sub(/^[[:space:]]*[-*][[:space:]]+/, "", text)
    text = strip_md(text)
    if (text == "") next
    nbullets++
    bullets[nbullets] = (section != "") ? "[" section "] " text : text
    next
}

END { flush() }
' <<< "$_combined"

entries=$(grep -c "^${PACKAGE} " "$OUTPUT" 2>/dev/null || echo 0)
log "Done: ${entries} entries written to ${OUTPUT} (up to ${RELEASE_TAG})"
