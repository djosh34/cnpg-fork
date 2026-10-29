#!/usr/bin/env bash
# The smallest scenario: shows which image each instance runs, writes on the
# primary and waits until both replicas have the write.
#
# A scenario gets the running Cluster pg in namespace default and KUBECONFIG,
# IMAGE and SRC in its environment, and fails the job by exiting non-zero.
set -euo pipefail

primary=$(kubectl get cluster pg -o jsonpath='{.status.currentPrimary}')
psql() { kubectl exec "$1" -c postgres -- psql -XqAt -v ON_ERROR_STOP=1 -c "$2"; }

kubectl get pods -l cnpg.io/cluster=pg -o wide
kubectl get pods -l cnpg.io/cluster=pg \
  -o jsonpath='{range .items[*]}{.metadata.name}: {.spec.initContainers[0].image} {.spec.containers[0].image}{"\n"}{end}'
psql "$primary" 'select version()'
psql "$primary" 'create table smoke (at timestamptz default now()); insert into smoke default values'
for pod in $(kubectl get pods -l cnpg.io/cluster=pg,cnpg.io/instanceRole=replica -o name); do
  until [[ $(psql "${pod#pod/}" 'select count(*) from smoke' 2>/dev/null) == 1 ]]; do sleep 1; done
  echo "${pod#pod/} has the write"
done
