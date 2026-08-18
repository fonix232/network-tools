#!/bin/bash
# Assemble nvme-watchdog.run — self-extracting installer with embedded payload.
#
# Usage: src/build.sh [output-path]
#   Default output: nvme-watchdog.run in the repo root for this installer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-"$SCRIPT_DIR/../nvme-watchdog.run"}"

# Verify sources exist
[[ -f "$SCRIPT_DIR/install.sh" ]]      || { echo "ERROR: install.sh not found" >&2; exit 1; }
[[ -f "$SCRIPT_DIR/nvme-recover.sh" ]] || { echo "ERROR: nvme-recover.sh not found" >&2; exit 1; }
[[ -f "$SCRIPT_DIR/nvme-poll.sh" ]]    || { echo "ERROR: nvme-poll.sh not found" >&2; exit 1; }

# Assemble: installer template (up to and including __PAYLOAD__) + base64 tarball payload
grep -q '^__PAYLOAD__$' "$SCRIPT_DIR/install.sh" \
    || { echo "ERROR: __PAYLOAD__ marker missing from install.sh" >&2; exit 1; }

cp "$SCRIPT_DIR/install.sh" "$OUT"
# COPYFILE_DISABLE: no macOS AppleDouble (._*) entries; --uid/--gid: root-owned on extraction
COPYFILE_DISABLE=1 tar -czf - --uid 0 --gid 0 -C "$SCRIPT_DIR" nvme-recover.sh nvme-poll.sh | base64 >> "$OUT"
chmod +x "$OUT"

echo "Built: $OUT ($(du -sh "$OUT" | cut -f1))"
