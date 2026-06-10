#!/usr/bin/env bash
# cluster/30-controller — gpu-node-controller pod that flips compute↔gaming
# on demand. Needs the agent token shared with the host-side gaming-agent.
#
# Token source order:
#   1. $AGENT_TOKEN env var (CI / explicit)
#   2. /tmp/.gpu-node-agent-token (left by host/85-gaming-agent)
#   3. ssh kai@172.16.1.220 'sudo cat /etc/gaming-agent/token' (network-fetch)
#   4. prompt
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

require kubectl

# Resolve the bearer token
if [ -n "${AGENT_TOKEN:-}" ]; then
  token="$AGENT_TOKEN"
elif [ -s /tmp/.gpu-node-agent-token ]; then
  token=$(cat /tmp/.gpu-node-agent-token)
elif token=$(ssh -o BatchMode=yes kai@172.16.1.220 'sudo cat /etc/gaming-agent/token' 2>/dev/null); then
  :
else
  read -r -s -p "AGENT_TOKEN: " token; echo
fi
[ -n "${token:-}" ] && [ "${#token}" -ge 32 ] || die "no valid agent token resolved"

# Secret (idempotent via dry-run + apply)
kubectl -n gpu-node-system create secret generic gpu-node-controller-secret \
  --from-literal=agent-token="$token" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "$REPO_ROOT/cluster/controller/04-configmap.yaml"
kubectl apply -f "$REPO_ROOT/cluster/controller/05-deployment.yaml"

# The running pod exec'd the OLD controller.sh from the previous ConfigMap
# mount — a ConfigMap-only change doesn't trigger a rollout by itself.
# Recreate strategy guarantees a single instance across the restart.
kubectl -n gpu-node-system rollout restart deployment/gpu-node-controller

echo "  waiting for controller rollout"
kubectl -n gpu-node-system rollout status deployment/gpu-node-controller --timeout=120s

# Clean up the temp token file
rm -f /tmp/.gpu-node-agent-token 2>/dev/null || true

ok "controller deployed"
