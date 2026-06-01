#!/usr/bin/env bash
set -euo pipefail

: "${BUILD_COMMAND:?BUILD_COMMAND is required}"

VERSION="${VERSION:-$(date -u +%Y.%m.%d)}"
export VERSION

cd /workspace
exec /bin/bash -lc "$BUILD_COMMAND"
