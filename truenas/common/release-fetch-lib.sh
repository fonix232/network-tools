#!/bin/sh
# Shared release tag fetching helpers for build scripts.

set -eu

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
