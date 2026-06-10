#!/usr/bin/env bash
# cluster/10-ns-rbac — gpu-node-system namespace + ServiceAccount/ClusterRole/Binding
# for the gpu-node-controller pod.
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

require kubectl

kubectl apply -f "$REPO_ROOT/cluster/controller/01-namespace.yaml"
kubectl apply -f "$REPO_ROOT/cluster/controller/02-rbac.yaml"

ok "namespace + RBAC applied"
