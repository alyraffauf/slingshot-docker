#!/usr/bin/env bash

set -euo pipefail
cd "$(dirname "$0")"

ENGINE="${ENGINE:-docker}" # docker | podman | buildah
IMAGE="${IMAGE:-slingshot}"
TAG="${TAG:-dev}"
REF="${IMAGE}:${TAG}"

args=(build -t "$REF" -f Dockerfile)
[ -n "${SLINGSHOT_REF:-}" ] && args+=(--build-arg "SLINGSHOT_REF=${SLINGSHOT_REF}")
[ "${PUSH:-0}" = "1" ] && [ "$ENGINE" = "docker" ] && args+=(--push)

echo "+ $ENGINE ${args[*]} ."
"$ENGINE" "${args[@]}" .

# podman/buildah push separately (no --push on plain build)
if [ "${PUSH:-0}" = "1" ] && [ "$ENGINE" != "docker" ]; then
    echo "+ $ENGINE push $REF"
    "$ENGINE" push "$REF"
fi
