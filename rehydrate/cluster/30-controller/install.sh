#!/usr/bin/env bash
# cluster/30-controller — gpu-node-controller pod that flips compute↔gaming
# on demand. Needs the agent token shared with the host-side gaming-agent:
# AGENT_TOKEN in .env, the same value host/85-gaming-agent installed.
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

require kubectl

require_agent_token

# Secret (idempotent via dry-run + apply)
kubectl -n gpu-node-system create secret generic gpu-node-controller-secret \
  --from-literal=agent-token="$AGENT_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "$REPO_ROOT/cluster/controller/04-configmap.yaml"
kubectl apply -f "$REPO_ROOT/cluster/controller/05-deployment.yaml"

# The running pod exec'd the OLD controller.sh from the previous ConfigMap
# mount — a ConfigMap-only change doesn't trigger a rollout by itself.
# Recreate strategy guarantees a single instance across the restart.
kubectl -n gpu-node-system rollout restart deployment/gpu-node-controller

echo "  waiting for controller rollout"
kubectl -n gpu-node-system rollout status deployment/gpu-node-controller --timeout=120s

ok "controller deployed"
