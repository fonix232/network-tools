#!/usr/bin/env bash
set -euo pipefail

# Fetches AMD NPU firmware from the AMD drm-firmware staging repository
# (gitlab.com/kernel-firmware/drm-firmware, branch: amd-ipu-staging).
# This is the authoritative source for dev firmware that XRT/amdxdna requires;
# linux-firmware.git only carries older production-release snapshots.
#
# For each device subdirectory the script creates two symlinks:
#   npu.dev.sbin -> latest <ver>_npu.sbin.*  (preferred by amdxdna driver)
#   npu.sbin     -> latest npu.sbin.*         (fallback path)
#
# No env vars required.
# Outputs: amdnpu-firmware/ directory in $PWD

GITLAB_REPO="https://gitlab.com/kernel-firmware/drm-firmware.git"
GITLAB_BRANCH="amd-ipu-staging"

mkdir -p amdnpu-firmware

echo "Fetching AMD NPU firmware from ${GITLAB_REPO} (${GITLAB_BRANCH})..."
git clone --depth 1 --branch "${GITLAB_BRANCH}" "${GITLAB_REPO}" fw-git
[[ -d fw-git/amdnpu ]] \
  || { echo "ERROR: amdnpu not found in drm-firmware repo" >&2; exit 1; }

rsync -a fw-git/amdnpu/ amdnpu-firmware/
git -C fw-git log -1 --format='%H %ai' > amdnpu-firmware/.pkg-version
echo "drm-firmware commit: $(cat amdnpu-firmware/.pkg-version)"
rm -rf fw-git

# Create firmware symlinks in each device subdirectory.
# npu.dev.sbin -> latest <ver>_npu.sbin.* (development/staging firmware,
#                 the name the amdxdna driver requests first via request_firmware)
# npu.sbin     -> latest npu.sbin.* (fallback name tried second by the driver)
find amdnpu-firmware -mindepth 1 -maxdepth 1 -type d | sort | while read -r dir; do
  subdir=$(basename "${dir}")

  # npu.dev.sbin: prefer <major.minor>_npu.sbin.* files (e.g. 1.7_npu.sbin.1.1.2.64)
  mapfile -t dev_candidates < <(
    find "${dir}" -maxdepth 1 -name '*_npu.sbin.*' | sort -V)
  if [[ ${#dev_candidates[@]} -gt 0 ]]; then
    latest="${dev_candidates[-1]}"
    ln -sf "$(basename "${latest}")" "${dir}/npu.dev.sbin"
    echo "  ${subdir}: npu.dev.sbin -> $(readlink "${dir}/npu.dev.sbin")"
  fi

  # npu.sbin: latest npu.sbin.* versioned file
  mapfile -t candidates < <(find "${dir}" -maxdepth 1 -name 'npu.sbin.*' | sort -V)
  if [[ ${#candidates[@]} -gt 0 ]]; then
    latest="${candidates[-1]}"
    ln -sf "$(basename "${latest}")" "${dir}/npu.sbin"
    echo "  ${subdir}: npu.sbin -> $(readlink "${dir}/npu.sbin")"
  fi

  if [[ ${#dev_candidates[@]} -eq 0 ]] && [[ ${#candidates[@]} -eq 0 ]]; then
    echo "  ${subdir}: WARNING: no firmware files found" >&2
  fi
done

echo "--- amdnpu firmware files ---"
find amdnpu-firmware -not -name '.pkg-version' | sort | \
  xargs -I{} sh -c 'if [ -L "{}" ]; then echo "  L {}  ->  $(readlink {})"; else echo "  F {}"; fi'
echo "-----------------------------"
