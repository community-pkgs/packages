#!/usr/bin/env bash
# generate-apt-index.sh
#
# Generate a styled index.html for an APT repository root.
#
# This script is package-agnostic and can be reused for any project by setting
# environment variables.
#
# Required (recommended) environment variables:
#   PROJECT_NAME         e.g. "Valkey"
#   PROJECT_SLUG         e.g. "valkey" (used in fallback URLs/titles)
#   REPO_URL             e.g. "https://github.com/owner/repo"
#   PAGES_URL            e.g. "https://owner.github.io/repo" (or custom domain)
#   RELEASE_TAG          e.g. "9.0.3"
#   MAJOR_VERSION        e.g. "9"
#
# Optional environment variables:
#   PROJECT_UPSTREAM_URL   e.g. "https://github.com/valkey-io/valkey"
#   PROJECT_README_URL     e.g. "https://github.com/owner/repo/blob/main/packages/valkey/README.md"
#   APT_BRANCH_URL         e.g. "https://github.com/owner/repo/tree/apt"
#   APT_SUITE_PREFIX       e.g. "valkey" -> produces suite "valkey9"
#   APT_DEFAULT_COMPONENT  e.g. "<CODENAME>" / "stable" / "main"
#   APT_INSTALL_PACKAGE    e.g. "valkey-server"
#   PROJECT_LOGO_PATH      e.g. "packages/valkey/logo.svg"
#                          Path to a square SVG logo for the package.
#                          If unset or the file does not exist, falls back to a
#                          📦 emoji on an orange gradient background.
#   MAINTAINER_EMAIL       e.g. "packages@example.com"
#   OUTPUT_PATH            e.g. "./repo/index.html"
#   BUILD_DATE             e.g. "2026-01-01 00:00 UTC"
#
# Notes:
# - If PROJECT_README_URL is unset, a fallback is built as:
#     "${REPO_URL}/blob/main/packages/${PROJECT_SLUG}/README.md"
# - If PROJECT_UPSTREAM_URL is unset, REPO_URL is used.

set -euo pipefail

# ----- defaults / fallbacks -----
: "${PROJECT_NAME:=Package}"
: "${PROJECT_SLUG:=package}"

: "${REPO_URL:=https://github.com/example/repo}"
: "${PAGES_URL:=https://example.github.io/repo}"

: "${PROJECT_UPSTREAM_URL:=$REPO_URL}"
: "${PROJECT_README_URL:=${REPO_URL}/blob/main/packages/${PROJECT_SLUG}/README.md}"
: "${APT_BRANCH_URL:=${REPO_URL}/tree/apt}"

: "${RELEASE_TAG:=unknown}"
: "${MAJOR_VERSION:=0}"

: "${APT_SUITE_PREFIX:=$PROJECT_SLUG}"
: "${APT_DEFAULT_COMPONENT:=<CODENAME>}"
: "${APT_INSTALL_PACKAGE:=${PROJECT_SLUG}-server}"

: "${MAINTAINER_EMAIL:=packages@example.com}"
: "${OUTPUT_PATH:=./index.html}"

if [[ -z "${BUILD_DATE:-}" ]]; then
  BUILD_DATE="$(date -u '+%Y-%m-%d %H:%M UTC')"
fi

# ----- derived values -----
APT_SUITE="${APT_SUITE_PREFIX}${MAJOR_VERSION}"
PAGE_TITLE="${PROJECT_NAME} APT Repository"

# ----- logo -----
# Build the CSS block and inner HTML for the logo area before the heredoc so
# that bash expansion works correctly inside the template.
if [[ -n "${PROJECT_LOGO_PATH:-}" && -f "$PROJECT_LOGO_PATH" ]]; then
  _logo_css='    .logo-icon {
      width: 42px; height: 42px;
      flex-shrink: 0;
      display: flex; align-items: center; justify-content: center;
    }
    .logo-icon svg { width: 42px; height: 42px; display: block; }'
  _logo_html="$(cat "$PROJECT_LOGO_PATH")"
else
  _logo_css='    .logo-icon {
      width: 42px; height: 42px;
      background: linear-gradient(135deg, #f78166 0%, #ff7b72 100%);
      border-radius: 10px;
      display: flex; align-items: center; justify-content: center;
      font-size: 1.4rem;
    }'
  _logo_html='📦'
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"

cat > "$OUTPUT_PATH" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>${PAGE_TITLE}</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
      background: #0d1117;
      color: #e6edf3;
      min-height: 100vh;
      display: flex;
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
    .logo {
      display: flex;
      align-items: center;
      gap: 0.75rem;
      margin-bottom: 1.25rem;
    }
${_logo_css}
    h1 { font-size: 1.55rem; font-weight: 700; color: #f0f6fc; }
    .subtitle {
      color: #8b949e;
      font-size: 0.95rem;
      margin-bottom: 1.5rem;
      line-height: 1.55;
    }
    .badge {
      display: inline-block;
      background: #21262d;
      border: 1px solid #30363d;
      border-radius: 20px;
      padding: 0.2rem 0.75rem;
      font-size: 0.8rem;
      color: #79c0ff;
      margin-bottom: 1.5rem;
    }
    .links { display: flex; flex-direction: column; gap: 0.8rem; margin-bottom: 1.5rem; }
    .link-item {
      display: flex;
      align-items: center;
      gap: 1rem;
      background: #21262d;
      border: 1px solid #30363d;
      border-radius: 8px;
      padding: 0.9rem 1rem;
      text-decoration: none;
      color: #e6edf3;
      transition: border-color 0.15s, background 0.15s;
    }
    .link-item:hover { border-color: #58a6ff; background: #1c2128; }
    .link-icon { font-size: 1.3rem; flex-shrink: 0; }
    .link-body { display: flex; flex-direction: column; gap: 0.15rem; }
    .link-title { font-weight: 600; font-size: 0.95rem; color: #f0f6fc; }
    .link-desc { font-size: 0.82rem; color: #8b949e; }

    .divider { border: none; border-top: 1px solid #30363d; margin: 1.25rem 0; }

    .install-block { margin-bottom: 1.25rem; }
    .install-label {
      font-size: 0.8rem;
      color: #8b949e;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      margin-bottom: 0.5rem;
    }
    pre {
      background: #0d1117;
      border: 1px solid #30363d;
      border-radius: 6px;
      padding: 0.85rem 1rem;
      font-size: 0.82rem;
      color: #a5d6ff;
      overflow-x: auto;
      line-height: 1.55;
      white-space: pre;
    }

    .footer {
      font-size: 0.78rem;
      color: #6e7681;
      text-align: center;
      line-height: 1.5;
    }
    .footer a { color: #58a6ff; text-decoration: none; }
    .footer a:hover { text-decoration: underline; }
  </style>
</head>
<body>
  <main class="card">
    <div class="logo">
      <div class="logo-icon">${_logo_html}</div>
      <h1>${PAGE_TITLE}</h1>
    </div>

    <p class="subtitle">
      Unofficial Debian/Ubuntu packages for
      <a href="${PROJECT_UPSTREAM_URL}" style="color:#58a6ff;text-decoration:none;">${PROJECT_NAME}</a>.
      Built automatically from upstream releases.
    </p>

    <div class="badge">Latest: v${RELEASE_TAG}</div>

    <section class="links">
      <a class="link-item" href="${PROJECT_README_URL}" target="_blank" rel="noopener">
        <span class="link-icon">📖</span>
        <span class="link-body">
          <span class="link-title">Installation Guide &amp; README</span>
          <span class="link-desc">Setup steps, package details, and usage notes</span>
        </span>
      </a>

      <a class="link-item" href="${APT_BRANCH_URL}" target="_blank" rel="noopener">
        <span class="link-icon">📦</span>
        <span class="link-body">
          <span class="link-title">APT Repository Files (apt branch)</span>
          <span class="link-desc">Signed .deb packages and metadata</span>
        </span>
      </a>

      <a class="link-item" href="${REPO_URL}" target="_blank" rel="noopener">
        <span class="link-icon">🛠️</span>
        <span class="link-body">
          <span class="link-title">Packaging Source Repository</span>
          <span class="link-desc">Workflow, Dockerfile, and Debian packaging files</span>
        </span>
      </a>

      <a class="link-item" href="${PROJECT_UPSTREAM_URL}" target="_blank" rel="noopener">
        <span class="link-icon">⬆️</span>
        <span class="link-body">
          <span class="link-title">Upstream Project</span>
          <span class="link-desc">${PROJECT_UPSTREAM_URL}</span>
        </span>
      </a>
    </section>

    <hr class="divider" />

    <section class="install-block">
      <div class="install-label">Quick install (set component for your distro)</div>
<pre>sudo mkdir -p /etc/apt/keyrings
curl -fsSL ${PAGES_URL}/public.asc | sudo gpg --dearmor -o /etc/apt/keyrings/${PROJECT_SLUG}.gpg
echo "deb [signed-by=/etc/apt/keyrings/${PROJECT_SLUG}.gpg] ${PAGES_URL} ${APT_SUITE} \$(. /etc/os-release && echo \"\${VERSION_CODENAME}\")" | sudo tee /etc/apt/sources.list.d/${PROJECT_SLUG}.list
sudo apt update && sudo apt install ${APT_INSTALL_PACKAGE}</pre>
    </section>

    <hr class="divider" />

    <p class="footer">
      Built on ${BUILD_DATE}<br />
      Maintained by <a href="mailto:${MAINTAINER_EMAIL}">${MAINTAINER_EMAIL}</a>
    </p>
  </main>
</body>
</html>
HTML
