#!/usr/bin/env bash
# Builds the operator image from a CNPG checkout the way its Dockerfile
# expects: a static manager binary in dist/manager/manager_<arch>. Tags it with
# a name no registry serves, so it can only come from the nodes' own store.
#
# Usage: bash ci/build-operator.sh <cnpg checkout>
set -euo pipefail

SRC=$1
ARCH=$(go env GOARCH)
COMMIT=$(git -C "$SRC" rev-parse --short HEAD)
IMAGE=cnpg-fork.local/cloudnative-pg:$COMMIT

PKG=github.com/cloudnative-pg/cloudnative-pg/pkg/versions
(
  cd "$SRC"
  CGO_ENABLED=0 GOOS=linux GOARCH=$ARCH go build -trimpath \
    -ldflags "-s -w -X $PKG.buildCommit=$COMMIT -X $PKG.buildDate=$(date -u +%F)" \
    -o "dist/manager/manager_$ARCH" ./cmd/manager
)
docker build -q -t "$IMAGE" "$SRC" >/dev/null
docker image ls "$IMAGE"
echo "IMAGE=$IMAGE" >>"$GITHUB_ENV"
