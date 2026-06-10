#!/usr/bin/env bash
# cluster/40-monitoring — DCGM-exporter DaemonSet + combined Grafana dashboard.
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

require kubectl

# DCGM-exporter. ORDER MATTERS: 04-custom-counters.yaml (the
# dcgm-exporter-counters ConfigMap) must exist BEFORE the daemonset — 02
# mounts it, and a pod scheduled without it sits in ContainerCreating.
# The custom CSV is what exposes CLOCKS_EVENT_REASONS + THERMAL_VIOLATION
# (the real Xid-79 heat-soak signature; DCGM_FI_DEV_MEMORY_TEMP is a
# constant 0 on consumer Ampere).
kubectl apply -f "$REPO_ROOT/cluster/monitoring/dcgm-exporter/01-rbac.yaml"
kubectl apply -f "$REPO_ROOT/cluster/monitoring/dcgm-exporter/04-custom-counters.yaml"
kubectl apply -f "$REPO_ROOT/cluster/monitoring/dcgm-exporter/02-daemonset.yaml"
kubectl apply -f "$REPO_ROOT/cluster/monitoring/dcgm-exporter/03-service-and-servicemonitor.yaml"

echo "  waiting for DCGM-exporter (first pull ~50 MB)"
kubectl -n gpu-node-system rollout status daemonset/dcgm-exporter --timeout=300s

# Combined dashboard ConfigMap (sidecar auto-loads via grafana_dashboard label)
kubectl apply -f "$REPO_ROOT/cluster/monitoring/dashboards/gpu-node-overview-configmap.yaml"

ok "DCGM-exporter + dashboard applied"
