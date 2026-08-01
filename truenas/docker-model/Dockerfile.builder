# Go-enabled variant of truenas/common/Dockerfile.builder.
# The docker-model CLI plugin has no standalone binary releases upstream
# (it ships only via Docker's deb/rpm trains), so it is compiled from source.
FROM --platform=linux/amd64 golang:1.25-alpine

RUN apk add --no-cache bash curl ca-certificates squashfs-tools coreutils

COPY truenas/common/sysext-build-lib.sh /usr/local/lib/sysext-build-lib.sh
COPY truenas/common/release-fetch-lib.sh /usr/local/lib/release-fetch-lib.sh
COPY truenas/common/builder-entrypoint.sh /usr/local/bin/truenas-builder-entrypoint
RUN chmod +x /usr/local/bin/truenas-builder-entrypoint

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/truenas-builder-entrypoint"]
