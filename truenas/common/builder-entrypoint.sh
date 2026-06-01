#!/usr/bin/env bash
set -euo pipefail

: "${PLUGIN_BUILD_SCRIPT:?PLUGIN_BUILD_SCRIPT is required}"

script_path="/workspace/${PLUGIN_BUILD_SCRIPT}"
if [[ ! -f "$script_path" ]]; then
  echo "ERROR: build script not found: $script_path" >&2
  exit 1
fi

exec /bin/sh "$script_path"
