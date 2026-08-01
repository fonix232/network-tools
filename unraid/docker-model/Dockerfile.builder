# Go-enabled variant of unraid/common/Dockerfile.builder.
# The docker-model CLI plugin has no standalone binary releases upstream
# (it ships only via Docker's deb/rpm trains), so it is compiled from source
# before the .plg is assembled.
FROM --platform=linux/amd64 golang:1.25-alpine

RUN apk add --no-cache bash curl ca-certificates python3 git tar xz

# The builder entrypoint uses a login shell, whose /etc/profile resets the
# PATH the golang image sets; make the toolchain reachable regardless.
RUN ln -s /usr/local/go/bin/go /usr/local/bin/go

COPY unraid/common/builder-entrypoint.sh /usr/local/bin/unraid-builder-entrypoint
RUN chmod +x /usr/local/bin/unraid-builder-entrypoint

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/unraid-builder-entrypoint"]
