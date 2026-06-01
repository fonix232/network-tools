FROM --platform=linux/amd64 python:3.12-alpine

RUN apk add --no-cache bash git tar xz

COPY unraid/common/builder-entrypoint.sh /usr/local/bin/unraid-builder-entrypoint
RUN chmod +x /usr/local/bin/unraid-builder-entrypoint

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/unraid-builder-entrypoint"]
