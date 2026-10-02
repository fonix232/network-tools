#!/bin/sh
# Shared version-pin and release-tag helpers for build scripts.

set -eu

# Read a pinned version out of a versions.env-style pin file.
# Blank lines, comment lines and trailing `# renovate: ...` annotations are
# ignored, so the value is whatever sits between `=` and the first space or
# `#`.
# Args:
#   $1 = variable name (e.g. KOMODO_VERSION)
#   $2 = pin file (default: /workspace/versions.env)
read_version_pin() {
    var_name="$1"
    pin_file="${2:-/workspace/versions.env}"

    if [ ! -f "$pin_file" ]; then
        echo "ERROR: version pin file not found: $pin_file" >&2
        return 1
    fi

    pin_value="$(sed -n "s/^[[:space:]]*${var_name}=\([^#[:space:]][^#[:space:]]*\).*/\1/p" \
        "$pin_file" | head -n 1)"

    if [ -z "$pin_value" ]; then
        echo "ERROR: no pin for ${var_name} in ${pin_file}" >&2
        return 1
    fi

    printf '%s\n' "$pin_value"
}

# Fetch stable tags from GitHub releases, deduplicated by major.minor.
# Args:
#   $1 = owner/repo
#   $2 = count
#   $3 = with_v_prefix (yes|no)
#   $4 = strict_v (yes|no)
fetch_latest_minor_tags() {
    repo="$1"
    count="$2"
    with_v="$3"
    strict_v="$4"

    if [ "$strict_v" = "yes" ]; then
        tag_regex='^v[0-9]+\.[0-9]+\.[0-9]+$'
    else
        tag_regex='^v?[0-9]+\.[0-9]+\.[0-9]+$'
    fi

    tags="$(curl -fsSL "https://api.github.com/repos/${repo}/releases?per_page=50" \
        | grep '"tag_name"' \
        | sed 's/.*"tag_name": "\(.*\)".*/\1/' \
        | grep -E "$tag_regex" \
        | sed 's/^v//' \
        | sort -t. -k1,1rn -k2,2rn -k3,3rn \
        | awk -F. '{ minor=$1"."$2; if (!seen[minor]++) print }' \
        | head -n "$count")"

    if [ -z "$tags" ]; then
        echo "ERROR: could not fetch releases from GitHub API for $repo" >&2
        return 1
    fi

    if [ "$with_v" = "yes" ]; then
        printf '%s\n' "$tags" | sed 's/^/v/'
    else
        printf '%s\n' "$tags"
    fi
}
