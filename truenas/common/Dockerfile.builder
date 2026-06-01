FROM --platform=linux/amd64 alpine:3

RUN apk add --no-cache bash curl ca-certificates squashfs-tools coreutils

COPY truenas/common/sysext-build-lib.sh /usr/local/lib/sysext-build-lib.sh
COPY truenas/common/release-fetch-lib.sh /usr/local/lib/release-fetch-lib.sh
COPY truenas/common/builder-entrypoint.sh /usr/local/bin/truenas-builder-entrypoint
RUN chmod +x /usr/local/bin/truenas-builder-entrypoint

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/truenas-builder-entrypoint"]
