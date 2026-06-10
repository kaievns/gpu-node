#!/usr/bin/env bash
# cluster/20-device-plugin — NVIDIA k8s-device-plugin DaemonSet.
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

require kubectl

kubectl apply -f "$REPO_ROOT/cluster/device-plugin/nvidia-device-plugin.yaml"

echo "  waiting for rollout"
kubectl -n kube-system rollout status daemonset/nvidia-device-plugin-daemonset --timeout=120s

ok "device plugin deployed"
