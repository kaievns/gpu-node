#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

ready=$(kubectl -n gpu-node-system get deploy gpu-node-controller \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
[ "${ready:-0}" -eq 1 ] && ok "controller deployment 1/1 Ready" || fail "controller not Ready"

# bootstrap log line proves agent reachability + healthy startup
kubectl -n gpu-node-system logs deployment/gpu-node-controller --tail=50 2>/dev/null \
  | grep -q 'bootstrap: agent reports mode=' \
  && ok "controller bootstrapped against agent" \
  || warn "no bootstrap log yet — controller may still be in apk add / kubectl download phase"

# is_streaming gate must be in the script (gaming-preempts-compute)
kubectl -n gpu-node-system get configmap gpu-node-controller-script \
  -o jsonpath='{.data.controller\.sh}' 2>/dev/null \
  | grep -q 'is_streaming' \
  && ok "controller script has streaming gate" \
  || fail "controller script missing is_streaming — ConfigMap is pre-fix"

# Mode taint should be present (controller applies it during bootstrap)
kubectl get node gpu-node -o jsonpath='{.spec.taints[?(@.key=="mode")].value}' 2>/dev/null \
  | grep -q gaming \
  && ok "mode=gaming:NoSchedule taint applied by controller" \
  || warn "mode taint not yet applied (controller still starting?)"
