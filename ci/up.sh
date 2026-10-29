#!/usr/bin/env bash
# Starts three k3s server nodes as docker containers, imports $IMAGE into each
# node's containerd, installs the operator from the checkout's config/ like a
# release manifest and waits for the Cluster in ci/cluster.yaml.
#
# Usage: IMAGE=<operator image> KUBECONFIG=<file> bash ci/up.sh <cnpg checkout>
set -euo pipefail

SRC=$(realpath "$1")
CI_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
: "${IMAGE:?}" "${KUBECONFIG:?}"
export KUBECONFIG

K3S_IMAGE=rancher/k3s:v1.37.1-k3s1@sha256:ca7f37d993d82ef0dcdcfecb2e0e2618ea541dbaffc620c8cedebe01a82acd0d
NODES=(k3s-1 k3s-2 k3s-3)
NODE_IPS=(10.77.0.11 10.77.0.12 10.77.0.13)

log() { echo "== $(date -u +%T) $*" >&2; }

# /tmp is a tmpfs because containerd tests idmapped mounts under /tmp at
# start, and they fail on docker's overlayfs.
start_node() {
  local i=$1 join=(--cluster-init)
  ((i == 0)) || join=(--server "https://${NODE_IPS[0]}:6443")
  docker run -d --name "${NODES[$i]}" --hostname "${NODES[$i]}" \
    --network ci --ip "${NODE_IPS[$i]}" \
    --privileged --tmpfs /run --tmpfs /var/run --tmpfs /tmp \
    -e K3S_TOKEN=ci-token -v "${NODES[$i]}:/var/lib/rancher/k3s" \
    "$K3S_IMAGE" server "${join[@]}" --node-ip "${NODE_IPS[$i]}" \
    --disable traefik >/dev/null
}

wait_for_node() {
  until kubectl get node "$1" >/dev/null 2>&1; do sleep 2; done
  kubectl wait --for=condition=Ready "node/$1" --timeout=300s >/dev/null
}

start_k3s() {
  mkdir -p "$(dirname "$KUBECONFIG")"
  docker network create --subnet 10.77.0.0/24 ci >/dev/null
  start_node 0
  until docker exec k3s-1 test -s /etc/rancher/k3s/k3s.yaml; do sleep 2; done
  docker exec k3s-1 cat /etc/rancher/k3s/k3s.yaml |
    sed "s#127.0.0.1#${NODE_IPS[0]}#" >"$KUBECONFIG"
  wait_for_node k3s-1
  for i in 1 2; do
    start_node "$i"
    wait_for_node "${NODES[$i]}"
  done
}

# Every node needs the image: the operator pod runs it, and each instance pod
# copies the manager binary from it in its bootstrap-controller init container.
import_image() {
  local node
  for node in "${NODES[@]}"; do
    docker save "$IMAGE" | docker exec -i "$node" ctr -n k8s.io images import - >/dev/null
  done
}

# Builds the manifest the way hack/release.sh builds releases/cnpg-<version>.yaml
# (config/default with the controller image set), then changes one line: the
# operator Deployment's imagePullPolicy: Always makes the kubelet ask a
# registry even when the node has the image.
install_operator() {
  make -C "$SRC" kustomize >/dev/null
  local config manifest=/tmp/ci/operator.yaml
  config=$(mktemp -d)
  cp -r "$SRC"/config/* "$config"
  (cd "$config/manager" && "$SRC/bin/kustomize" edit set image controller="$IMAGE")
  "$SRC/bin/kustomize" build "$config/default" >"$manifest"
  [[ $(grep -c 'imagePullPolicy: Always' "$manifest") == 1 ]]
  sed -i 's/imagePullPolicy: Always/imagePullPolicy: IfNotPresent/' "$manifest"
  kubectl apply --server-side -f "$manifest" >/dev/null
  kubectl rollout status deployment/cnpg-controller-manager -n cnpg-system --timeout=300s >/dev/null
}

create_cluster() {
  # The webhook can refuse requests for a few seconds after the rollout.
  until kubectl apply -f "$CI_DIR/cluster.yaml" >/dev/null; do sleep 2; done
  kubectl wait --for=condition=Ready cluster/pg --timeout=900s >/dev/null
}

log "starting k3s"
start_k3s
log "importing $IMAGE"
import_image
log "installing the operator"
install_operator
log "creating cluster pg"
create_cluster
log "ready"
kubectl get pods -A -o wide
