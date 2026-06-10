#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

# Custom counter ConfigMap (mounted by the daemonset — without it the pod
# never leaves ContainerCreating, and the thermal-violation panels show No data)
kubectl -n gpu-node-system get configmap dcgm-exporter-counters >/dev/null 2>&1 \
  && ok "dcgm-exporter-counters ConfigMap present" \
  || fail "dcgm-exporter-counters ConfigMap missing (apply 04-custom-counters.yaml)"

ready=$(kubectl -n gpu-node-system get ds dcgm-exporter -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
[ "${ready:-0}" -eq 1 ] && ok "DCGM-exporter pod 1/1 Ready" || fail "DCGM-exporter not Ready"

# ServiceMonitor exists with the magic label
kubectl -n gpu-node-system get servicemonitor dcgm-exporter \
  -o jsonpath='{.metadata.labels.release}' 2>/dev/null \
  | grep -q '^prometheus-stack$' \
  && ok "ServiceMonitor labeled release=prometheus-stack" \
  || fail "ServiceMonitor missing or wrong label"

# Dashboard ConfigMap discovered by Grafana sidecar
kubectl -n observability get configmap gpu-node-overview-dashboard >/dev/null 2>&1 \
  && ok "dashboard ConfigMap present" || fail "dashboard ConfigMap missing"
