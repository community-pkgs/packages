#!/usr/bin/env bash
# generate-root-index.sh
#
# Generate a styled root index.html for a multi-package APT repository.
#
# This page serves as the landing page for the GitHub Pages site and lists
# all available packages with links to their individual pages.
#
# Usage:
#   generate-root-index.sh [PACKAGE_ENTRY...]
#
#   Each PACKAGE_ENTRY is a pipe-separated string:
#     "slug|Display Name|Short description"
#
#   Example:
#     bash generate-root-index.sh \
#       "valkey|Valkey|High-performance in-memory data store (Redis fork)"
#
# Environment variables:
#   REPO_TITLE         Page / site title.
#                      Default: APT Package Repository
#   REPO_DESCRIPTION   Short paragraph shown under the title.
#                      Default: generic description
#   REPO_URL           URL to the packaging source repository on GitHub.
#                      Default: https://github.com/example/repo
#   PAGES_URL          GitHub Pages base URL (no trailing slash).
#                      Default: https://example.github.io/repo
#   MAINTAINER_EMAIL   Contact address shown in the footer.
#                      Default: packages@example.com
#   OUTPUT_PATH        Where to write the generated file.
#                      Default: ./index.html
#   BUILD_DATE         Human-readable build timestamp.
#                      Default: current UTC time

set -euo pipefail

# ── defaults ──────────────────────────────────────────────────────────────────
: "${REPO_TITLE:=APT Package Repository}"
: "${REPO_DESCRIPTION:=Unofficial Debian/Ubuntu packages built automatically from upstream releases.}"
: "${REPO_URL:=https://github.com/example/repo}"
: "${PAGES_URL:=https://example.github.io/repo}"
: "${MAINTAINER_EMAIL:=packages@example.com}"
: "${OUTPUT_PATH:=./index.html}"

if [[ -z "${BUILD_DATE:-}" ]]; then
  BUILD_DATE="$(date -u '+%Y-%m-%d %H:%M UTC')"
fi

# ── helpers ───────────────────────────────────────────────────────────────────
die() { printf '[generate-root-index] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[generate-root-index] %s\n' "$*" >&2; }

# ── parse package entries from positional arguments ───────────────────────────
# Each arg: "slug|Display Name|Short description"
package_cards_html=""

for entry in "$@"; do
  IFS='|' read -r slug name desc <<< "$entry"

  [[ -n "$slug" ]] || die "Empty slug in entry: '$entry'"
  [[ -n "$name" ]] || name="$slug"
  [[ -n "$desc" ]] || desc="APT packages for ${name}"

  package_url="${PAGES_URL}/${slug}/"
  package_rel_url="${slug}/"

  package_cards_html+="
      <a class=\"pkg-card\" href=\"${package_rel_url}\">
        <span class=\"pkg-icon\">📦</span>
        <span class=\"pkg-body\">
          <span class=\"pkg-name\">${name}</span>
          <span class=\"pkg-desc\">${desc}</span>
          <span class=\"pkg-url\">${package_url}</span>
        </span>
        <span class=\"pkg-arrow\">→</span>
      </a>"
done

if [[ -z "$package_cards_html" ]]; then
  package_cards_html="
      <p class=\"no-packages\">No packages configured yet.</p>"
fi

# ── emit HTML ─────────────────────────────────────────────────────────────────
mkdir -p "$(dirname "$OUTPUT_PATH")"
tmp="$(mktemp)"

cat > "$tmp" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>${REPO_TITLE}</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
                   "Helvetica Neue", Arial, sans-serif;
      background: #0d1117;
      color: #e6edf3;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      padding: 2rem 1rem;
    }

    .card {
      background: #161b22;
      border: 1px solid #30363d;
      border-radius: 12px;
      padding: 2.25rem 2.5rem;
      max-width: 760px;
      width: 100%;
      box-shadow: 0 8px 32px rgba(0,0,0,0.4);
    }

    /* ── header ── */
    .header {
      display: flex;
      align-items: center;
      gap: 0.75rem;
      margin-bottom: 1rem;
    }
    .header-icon {
      width: 46px; height: 46px;
      background: linear-gradient(135deg, #f78166 0%, #ff7b72 100%);
      border-radius: 10px;
      display: flex; align-items: center; justify-content: center;
      font-size: 1.5rem;
      flex-shrink: 0;
    }
    h1 { font-size: 1.6rem; font-weight: 700; color: #f0f6fc; }

    .subtitle {
      color: #8b949e;
      font-size: 0.95rem;
      margin-bottom: 1.75rem;
      line-height: 1.6;
    }
    .subtitle a { color: #58a6ff; text-decoration: none; }
    .subtitle a:hover { text-decoration: underline; }

    /* ── section label ── */
    .section-label {
      font-size: 0.78rem;
      color: #8b949e;
      text-transform: uppercase;
      letter-spacing: 0.06em;
      margin-bottom: 0.65rem;
    }

    /* ── package cards ── */
    .packages { display: flex; flex-direction: column; gap: 0.75rem; margin-bottom: 1.75rem; }

    .pkg-card {
      display: flex;
      align-items: center;
      gap: 1rem;
      background: #21262d;
      border: 1px solid #30363d;
      border-radius: 8px;
      padding: 1rem 1.1rem;
      text-decoration: none;
      color: #e6edf3;
      transition: border-color 0.15s, background 0.15s;
    }
    .pkg-card:hover { border-color: #58a6ff; background: #1c2128; }

    .pkg-icon { font-size: 1.5rem; flex-shrink: 0; }

    .pkg-body {
      display: flex;
      flex-direction: column;
      gap: 0.2rem;
      flex: 1;
      min-width: 0;
    }
    .pkg-name  { font-weight: 700; font-size: 1rem; color: #f0f6fc; }
    .pkg-desc  { font-size: 0.83rem; color: #8b949e; }
    .pkg-url   {
      font-size: 0.75rem;
      color: #58a6ff;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }

    .pkg-arrow { font-size: 1.1rem; color: #8b949e; flex-shrink: 0; }
    .pkg-card:hover .pkg-arrow { color: #58a6ff; }

    .no-packages { color: #6e7681; font-size: 0.9rem; padding: 0.5rem 0; }

    /* ── info row ── */
    .divider { border: none; border-top: 1px solid #30363d; margin: 1.25rem 0; }

    .info-links {
      display: flex;
      gap: 1rem;
      flex-wrap: wrap;
      margin-bottom: 1.25rem;
    }
    .info-link {
      display: flex;
      align-items: center;
      gap: 0.4rem;
      background: #21262d;
      border: 1px solid #30363d;
      border-radius: 6px;
      padding: 0.55rem 0.9rem;
      font-size: 0.85rem;
      color: #e6edf3;
      text-decoration: none;
      transition: border-color 0.15s, background 0.15s;
    }
    .info-link:hover { border-color: #58a6ff; background: #1c2128; }
    .info-link-icon { font-size: 1rem; }

    /* ── footer ── */
    .footer {
      font-size: 0.78rem;
      color: #6e7681;
      text-align: center;
      line-height: 1.55;
    }
    .footer a { color: #58a6ff; text-decoration: none; }
    .footer a:hover { text-decoration: underline; }
  </style>
</head>
<body>
  <main class="card">

    <div class="header">
      <div class="header-icon">📦</div>
      <h1>${REPO_TITLE}</h1>
    </div>

    <p class="subtitle">
      ${REPO_DESCRIPTION}<br />
      Each package has its own installation page linked below.
    </p>

    <p class="section-label">Available packages</p>

    <div class="packages">${package_cards_html}
    </div>

    <hr class="divider" />

    <div class="info-links">
      <a class="info-link" href="${REPO_URL}" target="_blank" rel="noopener">
        <span class="info-link-icon">🛠️</span>
        Packaging source
      </a>
      <a class="info-link" href="./public.asc" target="_blank" rel="noopener">
        <span class="info-link-icon">🔑</span>
        GPG public key
      </a>
    </div>

    <hr class="divider" />

    <p class="footer">
      Maintained by <a href="https://github.com/community-pkgs/packages">community-pkgs</a>
    </p>

  </main>
</body>
</html>
HTML

mv "$tmp" "$OUTPUT_PATH"
log "Generated $OUTPUT_PATH"
