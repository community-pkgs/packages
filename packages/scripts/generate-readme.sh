#!/usr/bin/env bash
# generate-readme.sh
#
# Generate a package README from a template and a GitHub Actions build matrix.
#
# The template must contain a placeholder that will be replaced with a
# generated Markdown table. By default that placeholder is:
#   {{SUPPORTED_DISTRIBUTIONS_TABLE}}
#
# Usage:
#   generate-readme.sh OUTPUT_PATH TEMPLATE_PATH WORKFLOW_PATH
#
#   Alternatively, set the three paths as environment variables:
#   OUTPUT_PATH=… TEMPLATE_PATH=… WORKFLOW_PATH=… generate-readme.sh
#
# Environment:
#   README_PLACEHOLDER        Placeholder to replace in the template.
#                             Default: {{SUPPORTED_DISTRIBUTIONS_TABLE}}
#   README_DISTRO_HEADER      Table header label for the distro column.
#                             Default: Distribution
#   README_CODENAME_HEADER    Table header label for the codename column.
#                             Default: Codename
#   README_ARCH_HEADER        Table header label for the architecture column.
#                             Default: Architecture
#   README_UBUNTU_SUFFIX      Suffix appended to Ubuntu versions in the table.
#                             Default:  LTS
#
# Additional substitutions:
#   Any {{KEY}} placeholder remaining in the template after the table
#   substitution is replaced if a matching environment variable KEY is set.
#   For example, if the template contains {{PAGES_URL}} and PAGES_URL is
#   exported, it will be replaced with the value of that variable.
#   Unset placeholders are left as-is so the caller can detect them.
#
# Notes:
# - This parser is intentionally lightweight and matches the current workflow
#   matrix layout:
#       matrix.os[].image
#       matrix.os[].codename
#       matrix.arch[]
# - It is reusable across packages, but it is not a general YAML parser.

set -euo pipefail

OUTPUT_PATH="${1:-}"
TEMPLATE_PATH="${2:-}"
WORKFLOW_PATH="${3:-}"

# Allow env var fallbacks so the script is callable both as:
#   generate-readme.sh OUTPUT TEMPLATE WORKFLOW   (positional args)
#   OUTPUT_PATH=… TEMPLATE_PATH=… WORKFLOW_PATH=… generate-readme.sh  (env vars)
: "${OUTPUT_PATH:?ERROR: OUTPUT_PATH is required (arg 1 or env var); e.g. packages/valkey/README.md}"
: "${TEMPLATE_PATH:?ERROR: TEMPLATE_PATH is required (arg 2 or env var); e.g. packages/valkey/README.md.in}"
: "${WORKFLOW_PATH:?ERROR: WORKFLOW_PATH is required (arg 3 or env var); e.g. .github/workflows/valkey-build.yml}"

PLACEHOLDER="${README_PLACEHOLDER:-{{SUPPORTED_DISTRIBUTIONS_TABLE}}}"
DISTRO_HEADER="${README_DISTRO_HEADER:-Distribution}"
CODENAME_HEADER="${README_CODENAME_HEADER:-Codename}"
ARCH_HEADER="${README_ARCH_HEADER:-Architecture}"
UBUNTU_SUFFIX="${README_UBUNTU_SUFFIX:- LTS}"

die() {
    printf '[generate-readme] ERROR: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '[generate-readme] %s\n' "$*" >&2
}

# Replace {{KEY}} placeholders where env var KEY is set; leave others unchanged.
substitute_env_placeholders() {
    local result="$1"
    local key value

    while [[ "$result" =~ \{\{([A-Z_][A-Z0-9_]*)\}\} ]]; do
        key="${BASH_REMATCH[1]}"
        if [[ -v "$key" ]]; then
            value="${!key}"
            result="${result/\{\{${key}\}\}/${value}}"
        else
            break
        fi
    done

    printf '%s' "$result"
}

[[ -f "$TEMPLATE_PATH" ]] || die "Template not found: $TEMPLATE_PATH"
[[ -f "$WORKFLOW_PATH" ]] || die "Workflow not found: $WORKFLOW_PATH"

template_content="$(cat "$TEMPLATE_PATH")"

case "$template_content" in
    *"$PLACEHOLDER"*) ;;
    *) die "Placeholder not found in template: $PLACEHOLDER" ;;
esac

format_distribution_name() {
    local image="$1"

    case "$image" in
        debian:*)
            printf 'Debian %s' "${image#debian:}"
            ;;
        ubuntu:*)
            printf 'Ubuntu %s%s' "${image#ubuntu:}" "$UBUNTU_SUFFIX"
            ;;
        *)
            printf '%s' "$image"
            ;;
    esac
}

make_separator_row() {
    local width="$1"
    local out=""
    local i

    for ((i = 0; i < width; i++)); do
        out+="-"
    done

    printf '%s' "$out"
}

os_images=()
os_codenames=()
arches=()

in_os=0
in_arch=0
current_image=""

while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    # Any top/job-level key resets state to avoid picking up duplicate sections.
    if [[ "$line" =~ ^[[:space:]]{0,4}[a-zA-Z_][a-zA-Z0-9_-]*:[[:space:]]*$ ]]; then
        case "$line" in
            *'os:'   ) in_os=1; in_arch=0; continue ;;
            *'arch:' ) in_os=0; in_arch=1; continue ;;
            *        ) in_os=0; in_arch=0; continue ;;
        esac
    fi

    if [[ $in_os -eq 1 ]]; then
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*image:[[:space:]]*\"?([^\"[:space:]]+)\"?[[:space:]]*$ ]]; then
            current_image="${BASH_REMATCH[1]}"
            continue
        fi

        if [[ "$line" =~ ^[[:space:]]*codename:[[:space:]]*\"?([^\"[:space:]]+)\"?[[:space:]]*$ ]]; then
            [[ -n "$current_image" ]] || die "Found codename before image in workflow matrix"
            os_images+=("$current_image")
            os_codenames+=("${BASH_REMATCH[1]}")
            current_image=""
            continue
        fi
    fi

    if [[ $in_arch -eq 1 ]]; then
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*([a-z0-9_-]+)[[:space:]]*$ ]]; then
            arches+=("${BASH_REMATCH[1]}")
            continue
        fi
    fi
done < "$WORKFLOW_PATH"

[[ ${#os_images[@]} -gt 0 ]] || die "Could not parse any matrix.os entries from workflow"
[[ ${#arches[@]} -gt 0 ]] || die "Could not parse any matrix.arch entries from workflow"

arch_md=""
for arch in "${arches[@]}"; do
    if [[ -n "$arch_md" ]]; then
        arch_md+=", "
    fi
    arch_md+="\`$arch\`"
done

table="| ${DISTRO_HEADER} | ${CODENAME_HEADER} | ${ARCH_HEADER} |
| $(make_separator_row "${#DISTRO_HEADER}") | $(make_separator_row "${#CODENAME_HEADER}") | $(make_separator_row "${#ARCH_HEADER}") |"

for i in "${!os_images[@]}"; do
    image="${os_images[$i]}"
    codename="${os_codenames[$i]}"
    distro="$(format_distribution_name "$image")"

    printf -v row '| %s | `%s` | %s |' "$distro" "$codename" "$arch_md"
    table+=$'\n'"$row"
done

mkdir -p "$(dirname "$OUTPUT_PATH")"

tmp_output="$(mktemp)"

while IFS= read -r line; do
    if [[ "$line" == "$PLACEHOLDER" ]]; then
        printf '%s\n' "$table"
    else
        printf '%s\n' "$(substitute_env_placeholders "$line")"
    fi
done < "$TEMPLATE_PATH" > "$tmp_output"

mv "$tmp_output" "$OUTPUT_PATH"

log "Generated $OUTPUT_PATH from $TEMPLATE_PATH"
