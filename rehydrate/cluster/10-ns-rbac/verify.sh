#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

kubectl get namespace gpu-node-system >/dev/null 2>&1 \
  && ok "namespace gpu-node-system exists" || fail "namespace missing"

kubectl -n gpu-node-system get serviceaccount gpu-node-controller >/dev/null 2>&1 \
  && ok "SA gpu-node-controller exists" || fail "SA missing"

kubectl get clusterrolebinding gpu-node-controller >/dev/null 2>&1 \
  && ok "ClusterRoleBinding gpu-node-controller exists" || fail "binding missing"
