#!/bin/bash
# Best-effort: remove the Model Runner container/images before the CLI goes
# away. Models live in a docker volume and are preserved.
if docker info >/dev/null 2>&1 && [ -x /usr/local/lib/docker/cli-plugins/docker-model ]; then
    docker model uninstall-runner 2>/dev/null || true
fi

rm -f /usr/local/lib/docker/cli-plugins/docker-model
rm -rf /usr/local/emhttp/plugins/docker-model

echo "docker-model plugin removed. Downloaded models (docker volume) preserved —"
echo "run 'docker volume rm docker-model-runner-models' to delete them."
echo "Cached binary preserved at /boot/config/plugins/docker-model/ — remove manually if no longer needed."
