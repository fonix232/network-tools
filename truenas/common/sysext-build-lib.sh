#!/bin/sh
# Shared helpers for TrueNAS sysext .run builders.

set -eu

require_env() {
    var_name="$1"
    eval "val=\${$var_name:-}"
    if [ -z "$val" ]; then
        echo "ERROR: required env var not set: $var_name" >&2
        exit 1
    fi
}

map_sysext_arch() {
    case "$1" in
        aarch64) echo "arm64" ;;
        *)       echo "x86-64" ;;
    esac
}

reset_sysext_tree() {
    rm -rf /sysext
    mkdir -p /sysext/usr/bin /sysext/usr/lib/extension-release.d
}

write_extension_release() {
    ext_name="$1"
    sysext_arch="$2"
    printf 'ID=_any\nARCHITECTURE=%s\nEXTENSION_RELOAD_MANAGER=1\n' "$sysext_arch" \
        > "/sysext/usr/lib/extension-release.d/extension-release.${ext_name}"
}

pack_and_wrap_installer() {
    raw_name="$1"
    output_path="$2"
    template_path="${3:-/install.sh.template}"

    mksquashfs /sysext "/tmp/${raw_name}.raw" -comp zstd -noappend -no-progress

    cp "$template_path" "$output_path"
    printf '\n__PAYLOAD__\n' >> "$output_path"
    base64 "/tmp/${raw_name}.raw" >> "$output_path"
    chmod +x "$output_path"
}
