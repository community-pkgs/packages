#!/usr/bin/env bash
# generate-apt-index.sh
#
# Generate a styled index.html for an APT package repository.
#
# Required:
#   PROJECT_NAME         e.g. "Valkey"
#   PROJECT_SLUG         e.g. "valkey"
#   REPO_URL             e.g. "https://github.com/owner/repo"
#   PAGES_URL            e.g. "https://owner.github.io/repo"
#   RELEASES_JSON        e.g. '[{"tag":"9.0.3","major":"9"},{"tag":"8.1.0","major":"8"}]'
#
# Optional:
#   PROJECT_UPSTREAM_URL   Default: REPO_URL
#   PROJECT_README_URL     Default: REPO_URL/blob/main/packages/PROJECT_SLUG/README.md
#   APT_SUITE_PREFIX       e.g. "valkey" → suite "valkey9". Default: PROJECT_SLUG
#   APT_INSTALL_PACKAGE    Default: PROJECT_SLUG-server
#   PROJECT_LOGO_PATH      Square SVG logo. Falls back to 📦 emoji if unset/missing.
#   OUTPUT_PATH            Default: ./index.html
#   BUILD_DATE             Default: current UTC time

set -euo pipefail

: "${PROJECT_NAME:=Package}"
: "${PROJECT_SLUG:=package}"

: "${REPO_URL:=https://github.com/example/repo}"
: "${PAGES_URL:=https://example.github.io/repo}"

: "${PROJECT_UPSTREAM_URL:=$REPO_URL}"
: "${PROJECT_README_URL:=${REPO_URL}/blob/main/packages/${PROJECT_SLUG}/README.md}"


: "${RELEASE_TAG:=unknown}"
: "${MAJOR_VERSION:=0}"

if [[ -z "${RELEASES_JSON:-}" ]]; then
  RELEASES_JSON="[{\"tag\":\"${RELEASE_TAG}\",\"major\":\"${MAJOR_VERSION}\"}]"
fi

: "${APT_SUITE_PREFIX:=$PROJECT_SLUG}"

: "${APT_INSTALL_PACKAGE:=${PROJECT_SLUG}-server}"
: "${APT_COMPONENT:=}"

if ! echo "$RELEASES_JSON" | jq -e 'type == "array" and length > 0' > /dev/null 2>&1; then
  echo "generate-apt-index: WARNING: RELEASES_JSON is empty or invalid, falling back to RELEASE_TAG" >&2
  RELEASES_JSON="[{\"tag\":\"${RELEASE_TAG}\",\"major\":\"${MAJOR_VERSION}\"}]"
fi

: "${OUTPUT_PATH:=./index.html}"

RELEASES_JSON="$(echo "$RELEASES_JSON" | jq -c '[sort_by(.major | if . == "" then 0 else tonumber end) | reverse[]]')"

_release_count="$(echo "$RELEASES_JSON" | jq 'length')"

if [[ -z "${BUILD_DATE:-}" ]]; then
  BUILD_DATE="$(date -u '+%Y-%m-%d %H:%M UTC')"
fi

PAGE_TITLE="${PROJECT_NAME} APT Repository"

# latest tag for version badge
_latest_tag="$(echo "$RELEASES_JSON" | jq -r '[sort_by(.major | if . == "" then 0 else tonumber end) | reverse[]][0].tag')"

# Helper: derive a stable tab identifier from a release entry.
# For multi-major (major != ""), use the major number.
# For single-suite (major == ""), use "latest".
_tab_id_for() {
  local m="$1"
  if [[ -n "$m" ]]; then printf '%s' "$m"; else printf 'latest'; fi
}

if [[ "$_release_count" -eq 1 ]]; then
  # ── Single-suite: no tabs, just a code block ──
  _single_rel="$(echo "$RELEASES_JSON" | jq -c '.[0]')"
  _single_tag="$(echo "$_single_rel" | jq -r '.tag')"
  _single_major="$(echo "$_single_rel" | jq -r '.major')"
  _single_suite="${APT_SUITE_PREFIX}${_single_major}"

  _tab_inputs=""
  _tab_labels_html=""
  _tab_css_rules=""
  _tab_panels_html="$(cat <<ENDPANEL
      <div class="tab-panel" style="display:block">
        <pre>sudo mkdir -p /etc/apt/keyrings
curl -fsSL ${PAGES_URL}/public.asc | sudo gpg --dearmor -o /etc/apt/keyrings/${PROJECT_SLUG}.gpg
echo "deb [signed-by=/etc/apt/keyrings/${PROJECT_SLUG}.gpg] ${PAGES_URL} ${_single_suite} ${APT_COMPONENT:-\$(. /etc/os-release && echo "\${VERSION_CODENAME}")}" \\
  | sudo tee /etc/apt/sources.list.d/${PROJECT_SLUG}.list
echo -e 'Package: *\nPin: release a=${_single_suite}\nPin-Priority: 1001' \\
  | sudo tee /etc/apt/preferences.d/${PROJECT_SLUG}
sudo apt update && sudo apt install ${APT_INSTALL_PACKAGE}</pre>
      </div>
ENDPANEL
)"

else
  # ── Multi-major: tabbed interface ──

  # tabs: radio inputs
  _tab_inputs=""
  _first_tab=true
  while IFS= read -r rel; do
    major="$(echo "$rel" | jq -r '.major')"
    tab_id="$(_tab_id_for "$major")"
    if [[ "$_first_tab" == "true" ]]; then
      _tab_inputs+="  <input type=\"radio\" name=\"vtab\" id=\"tab-major-${tab_id}\" class=\"tab-input\" checked>"$'\n'
      _first_tab=false
    else
      _tab_inputs+="  <input type=\"radio\" name=\"vtab\" id=\"tab-major-${tab_id}\" class=\"tab-input\">"$'\n'
    fi
  done < <(echo "$RELEASES_JSON" | jq -c '.[]')

  # tabs: labels
  _tab_labels_html=""
  while IFS= read -r rel; do
    major="$(echo "$rel" | jq -r '.major')"
    tag="$(echo "$rel" | jq -r '.tag')"
    tab_id="$(_tab_id_for "$major")"
    if [[ -n "$major" ]]; then
      tab_label="${PROJECT_NAME} ${major}.x"
    else
      tab_label="${PROJECT_NAME} v${tag}"
    fi
    _tab_labels_html+="      <label for=\"tab-major-${tab_id}\" class=\"tab-label\">${tab_label}<span class=\"tab-version\">v${tag}</span></label>"$'\n'
  done < <(echo "$RELEASES_JSON" | jq -c '.[]')

  # tabs: panels
  _tab_panels_html=""
  while IFS= read -r rel; do
    tag="$(echo "$rel" | jq -r '.tag')"
    major="$(echo "$rel" | jq -r '.major')"
    tab_id="$(_tab_id_for "$major")"
    suite="${APT_SUITE_PREFIX}${major}"
    _tab_panels_html+="$(cat <<ENDPANEL
      <div class="tab-panel" data-major="${tab_id}">
        <pre>sudo mkdir -p /etc/apt/keyrings
curl -fsSL ${PAGES_URL}/public.asc | sudo gpg --dearmor -o /etc/apt/keyrings/${PROJECT_SLUG}.gpg
echo "deb [signed-by=/etc/apt/keyrings/${PROJECT_SLUG}.gpg] ${PAGES_URL} ${suite} ${APT_COMPONENT:-\$(. /etc/os-release && echo "\${VERSION_CODENAME}")}" \\
  | sudo tee /etc/apt/sources.list.d/${PROJECT_SLUG}.list
echo -e 'Package: *\nPin: release a=${suite}\nPin-Priority: 1001' \
  | sudo tee /etc/apt/preferences.d/${PROJECT_SLUG}
sudo apt update && sudo apt install ${APT_INSTALL_PACKAGE}</pre>
      </div>
ENDPANEL
)"$'\n'
  done < <(echo "$RELEASES_JSON" | jq -c '.[]')

  # tabs: per-major CSS rules
  _tab_css_rules=""
  while IFS= read -r rel; do
    major="$(echo "$rel" | jq -r '.major')"
    tab_id="$(_tab_id_for "$major")"
    _tab_css_rules+="    #tab-major-${tab_id}:checked ~ .tabs-wrapper .tab-panel[data-major=\"${tab_id}\"] { display: block; }"$'\n'
    _tab_css_rules+="    #tab-major-${tab_id}:checked ~ .tabs-wrapper .tab-bar label[for=\"tab-major-${tab_id}\"] { background: #1c2128; border-color: #58a6ff; color: #58a6ff; border-bottom-color: #1c2128; }"$'\n'
  done < <(echo "$RELEASES_JSON" | jq -c '.[]')
fi

# logo + favicon
_favicon_href='data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>📦</text></svg>'

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
  <link rel="icon" href="${_favicon_href}" />
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
    .version-badge {
      display: inline-block;
      font-size: 0.75rem;
      font-weight: 600;
      font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
      color: #79c0ff;
      background: #1f3a5c;
      border: 1px solid #1f6feb;
      border-radius: 20px;
      padding: 0.2rem 0.6rem;
      margin-left: 0.5rem;
      vertical-align: middle;
      white-space: nowrap;
    }
    .subtitle {
      color: #8b949e;
      font-size: 0.95rem;
      margin-bottom: 1.5rem;
      line-height: 1.55;
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

    /* ── Tabs ──────────────────────────────────────────────────── */
    .tab-input { display: none; }
    .tab-panel  { display: none; }

${_tab_css_rules}
    .tabs-container { margin-bottom: 0.25rem; }

    .tab-bar {
      display: flex;
      flex-wrap: wrap;
      gap: 0.25rem;
      margin-bottom: -1px;
      position: relative;
      z-index: 1;
    }
    .tab-label {
      display: inline-flex;
      align-items: center;
      gap: 0.5rem;
      padding: 0.45rem 1rem;
      cursor: pointer;
      border: 1px solid #30363d;
      border-bottom: 1px solid #30363d;
      border-radius: 6px 6px 0 0;
      background: #0d1117;
      color: #8b949e;
      font-size: 0.88rem;
      font-weight: 500;
      user-select: none;
      transition: color 0.12s, background 0.12s, border-color 0.12s;
    }
    .tab-label:hover { color: #e6edf3; background: #161b22; border-color: #484f58; }
    .tab-version {
      font-size: 0.75rem;
      color: #6e7681;
      font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
    }

    .tab-panels {
      border: 1px solid #30363d;
      border-radius: 0 6px 6px 6px;
      background: #1c2128;
      padding: 1rem;
    }
    .tab-panel pre {
      background: #0d1117;
      border: 1px solid #30363d;
      border-radius: 6px;
      padding: 0.85rem 1rem;
      font-size: 0.82rem;
      color: #a5d6ff;
      overflow-x: auto;
      line-height: 1.65;
      white-space: pre;
      font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
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
      <h1>${PAGE_TITLE}<span class="version-badge">v${_latest_tag}</span></h1>
    </div>

    <p class="subtitle">
      Unofficial Debian/Ubuntu packages for
      <a href="${PROJECT_UPSTREAM_URL}" style="color:#58a6ff;text-decoration:none;">${PROJECT_NAME}</a>.
      Built automatically from upstream releases.
    </p>

    <section class="links">
      <a class="link-item" href="${PROJECT_README_URL}" target="_blank" rel="noopener">
        <span class="link-icon">📖</span>
        <span class="link-body">
          <span class="link-title">Installation Guide &amp; README</span>
          <span class="link-desc">Setup steps, package details, and usage notes</span>
        </span>
      </a>

      <a class="link-item" href="${PAGES_URL}" target="_blank" rel="noopener">
        <span class="link-icon">🗂️</span>
        <span class="link-body">
          <span class="link-title">Browse All Available Packages</span>
          <span class="link-desc">All available package repositories</span>
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

    <div class="tabs-container">
${_tab_inputs}
      <div class="tabs-wrapper">
        <div class="tab-bar">
${_tab_labels_html}
        </div>
        <div class="tab-panels">
${_tab_panels_html}
        </div>
      </div>
    </div>

    <hr class="divider" />

    <p class="footer">
      Built on ${BUILD_DATE}<br />
      Maintained by <a href="${REPO_URL}" target="_blank" rel="noopener">${REPO_URL}</a>
    </p>
  </main>
</body>
</html>
HTML
