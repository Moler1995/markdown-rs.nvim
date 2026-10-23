#!/usr/bin/env bash
# Check the README as a landing page.
#
# Three rules, all of them offline:
#
#   * every section a landing page needs is present;
#   * every relative link points at a tracked file;
#   * the retired `g:md_render_binary` key and drive-letter paths are gone.
#
# Run from anywhere in the checkout. Pass a different file as the first
# argument to check a copy.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

readme=${1:-README.md}
status=0

note() {
    printf '%s\n' "$*" >&2
    status=1
}

required=(
    'Features'
    'Requirements'
    'Installation'
    'Quick start'
    'Configuration'
    'Commands and keymaps'
    'Troubleshooting'
    'Development'
    'Architecture'
    'Contributing'
    'License'
)

for section in "${required[@]}"; do
    if ! grep -Eiq "^#{1,6}[[:space:]]+${section}([[:space:]]|$)" "$readme"; then
        note "README: missing section: $section"
    fi
done

if grep -q 'g:md_render_binary' "$readme"; then
    note 'README: names the retired g:md_render_binary option'
fi

if grep -Eq '(^|[^[:alnum:]+.-])[A-Za-z]:[\\/]' "$readme"; then
    note 'README: contains a drive-letter path'
fi

# Links are only links outside code. Drop fenced blocks, then inline spans.
body=$(
    awk '/^[[:space:]]*```/{fence = !fence; next} !fence' "$readme" |
        sed -E 's/`[^`]*`//g'
)

# Inline links and images: [text](target) and ![alt](target).
targets=$(
    printf '%s\n' "$body" |
        grep -oE '\]\([^)]*\)' |
        sed -E 's/^\]\(//; s/\)$//' || true
)

# Reference definitions: [id]: target
targets+=$'\n'$(
    printf '%s\n' "$body" |
        grep -Eo '^\[[^]]+\]:[[:space:]]*[^[:space:]]+' |
        sed -E 's/^\[[^]]+\]:[[:space:]]*//' || true
)

while IFS= read -r target; do
    target=${target%%#*}
    target=${target%%\?*}
    target=${target#<}
    target=${target%>}

    [ -z "$target" ] && continue

    # Absolute URLs, protocol-relative URLs and mail links are not files.
    case "$target" in
        *:* | //*) continue ;;
    esac

    if git ls-files --error-unmatch -- "$target" >/dev/null 2>&1; then
        continue
    fi

    if [ -d "$target" ] && [ -n "$(git ls-files -- "$target")" ]; then
        continue
    fi

    note "README: link target is not tracked: $target"
done <<<"$targets"

exit "$status"
