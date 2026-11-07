#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

kubectl get runtimeclass nvidia >/dev/null 2>&1 \
  && ok "RuntimeClass nvidia present" || fail "RuntimeClass nvidia missing"

ready=$(kubectl -n kube-system get ds nvidia-device-plugin-daemonset \
  -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
[ "${ready:-0}" -ge 1 ] && ok "device plugin pod Ready ($ready)" || fail "no device plugin pods ready"

# Most important check: allocatable, because capacity stays 1 when the plugin marks the GPU unhealthy
gpu=$(kubectl get node gpu-node -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo 0)
[ "${gpu:-0}" -ge 1 ] && ok "gpu-node has allocatable nvidia.com/gpu: $gpu" || fail "nvidia.com/gpu is not allocatable on gpu-node (plugin marked it unhealthy?)"
