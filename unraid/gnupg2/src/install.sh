#!/bin/bash
# gnupg2 plugin — install script
# Downloads gnupg2 + dependencies from Slackware mirror to /boot/extra/.
set -e

EXTRA_DIR="/boot/extra"
PKG_DB="/var/lib/pkgtools/packages"
PACKAGES="gnupg2 libassuan libksba npth"

# Look up a package path from CHECKSUMS.md5 (returns category/filename)
lookup_package() {
    local name="$1"
    echo "$CHECKSUMS" | grep -oP "(?<=\./)slackware64/[^/]+/${name}-[^\s]+\.txz(?=\s|$)" | head -1
}
FLASH_GPG="/boot/config/gnupg"

# Detect Slackware base — Unraid 7.x reports "Slackware 15.0+" but tracks -current
SLACK_VER=$(cat /etc/slackware-version 2>/dev/null)
if echo "$SLACK_VER" | grep -qP '\+$'; then
    MIRROR="https://mirrors.slackware.com/slackware/slackware64-current"
else
    SLACK_NUM=$(echo "$SLACK_VER" | grep -oP '[\d.]+')
    MIRROR="https://mirrors.slackware.com/slackware/slackware64-${SLACK_NUM:-current}"
fi

echo "gnupg2: using mirror $MIRROR"

mkdir -p "$EXTRA_DIR"
mkdir -p "/usr/local/emhttp/plugins/gnupg2/event"

# Fetch CHECKSUMS.md5 to find latest package filenames
CHECKSUMS=$(curl -fsSL "$MIRROR/CHECKSUMS.md5" 2>/dev/null) || {
    echo "gnupg2: WARNING — could not fetch CHECKSUMS.md5, skipping package download"
    echo "gnupg2: use the web UI to download packages later"
    exit 0
}

for name in $PACKAGES; do
    pkg_path=$(lookup_package "$name")
    if [ -z "$pkg_path" ]; then
        echo "gnupg2: $name — not found in mirror"
        continue
    fi

    filename=$(basename "$pkg_path")
    url="$MIRROR/$pkg_path"

    # Check if already in /boot/extra
    if [ -f "$EXTRA_DIR/$filename" ]; then
        echo "gnupg2: $name — $filename already in /boot/extra"
        continue
    fi

    # Remove old versions
    rm -f "$EXTRA_DIR"/$name-*.t?z

    echo "gnupg2: downloading $name — $filename"
    curl -fsSL "$url" -o "$EXTRA_DIR/$filename" || {
        echo "gnupg2: $name — download failed"
        continue
    }

    upgradepkg --install-new "$EXTRA_DIR/$filename" 2>&1
done

# Restore GPG keyring if backup exists
if [ -d "$FLASH_GPG" ]; then
    mkdir -p /root/.gnupg
    chmod 700 /root/.gnupg
    rsync -a --exclude='S.*' --exclude='*.lock' --exclude='.#lk*' \
        "$FLASH_GPG/" /root/.gnupg/
    echo "gnupg2: restored keyring from flash"
fi

echo "gnupg2: install complete"
gpg --version | head -1 || true
