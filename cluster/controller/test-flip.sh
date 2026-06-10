#!/usr/bin/env bash
# End-to-end smoke test for the gpu-node-controller lifecycle.
#
# What this does:
#   1. Applies a Pending GPU pod (CUDA base + nvidia-smi).
#   2. Tails controller logs while it observes the pending pod and flips to
#      compute mode (POSTs /mode/compute on the agent, removes the gaming
#      taint).
#   3. Waits for the pod to schedule + run + exit.
#   4. Deletes the pod (so the cooldown timer starts).
#   5. Skips the 5-minute cooldown by calling /mode/gaming directly +
#      re-applying the gaming taint manually.
#
# Run when you are NOT actively streaming. The gaming stack restarts mid-test
# (~30 s of unavailability total).
set -euo pipefail

NS=gpu-node-system
NODE=gpu-node
AGENT_URL=${AGENT_URL:-http://172.16.1.220:8080}
GPU_NODE_SSH=${GPU_NODE_SSH:-kai@172.16.1.220}

step() { echo; echo "═══════ $* ═══════"; }

step "0. Prereq check — controller running, agent reachable"
kubectl -n "$NS" rollout status deployment/gpu-node-controller --timeout=30s
TOKEN=$(ssh "$GPU_NODE_SSH" 'sudo cat /etc/gaming-agent/token')
curl -fsS -H "Authorization: Bearer $TOKEN" "$AGENT_URL/status" | python3 -m json.tool

step "1. Apply test GPU pod (will be Pending until controller flips)"
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gpu-flip-test
  namespace: default
spec:
  runtimeClassName: nvidia
  restartPolicy: Never
  tolerations:
    - {key: gpu, operator: Equal, value: "true", effect: NoSchedule}
    - {key: dynamic-node, operator: Equal, value: "true", effect: NoSchedule}
  containers:
    - name: nvsmi
      image: nvcr.io/nvidia/cuda:12.6.0-base-ubuntu24.04
      command: ["bash", "-c"]
      args: ["nvidia-smi; echo SLEEPING 30s; sleep 30; echo DONE"]
      resources:
        limits: {nvidia.com/gpu: "1"}
YAML

step "2. Tail controller logs in background while we wait"
kubectl -n "$NS" logs -f deployment/gpu-node-controller &
LOG_PID=$!
trap "kill $LOG_PID 2>/dev/null || true" EXIT

step "3. Wait for pod to start (controller has to flip first)"
# Not `kubectl wait --for=condition=Ready`: a fast pod can run and exit
# between polls, leaving Ready=False (Succeeded) and the wait timing out
# even though everything worked. Poll the phase instead and accept either.
deadline=$(( $(date +%s) + 180 ))
while :; do
  phase=$(kubectl -n default get pod gpu-flip-test -o jsonpath='{.status.phase}' 2>/dev/null || true)
  case "$phase" in
    Running|Succeeded) echo "pod phase: $phase"; break ;;
    Failed) echo "pod FAILED:"; kubectl -n default describe pod gpu-flip-test | tail -20; exit 1 ;;
  esac
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "timed out waiting for pod (last phase: ${phase:-unknown})"
    exit 1
  fi
  sleep 3
done

step "4. Stream the pod logs (nvidia-smi output)"
kubectl -n default logs gpu-flip-test -f

step "5. Pod done. Delete it so the cooldown starts."
kubectl -n default delete pod gpu-flip-test

step "6. Skip the 5-min cooldown — manually call /mode/gaming + re-add taint"
echo "Calling /mode/gaming to bring gaming stack back up immediately..."
curl -fsS -X POST -H "Authorization: Bearer $TOKEN" "$AGENT_URL/mode/gaming" \
  | python3 -m json.tool
echo "Re-adding mode=gaming:NoSchedule taint..."
kubectl taint nodes "$NODE" mode=gaming:NoSchedule --overwrite

step "7. Final state"
curl -fsS -H "Authorization: Bearer $TOKEN" "$AGENT_URL/status" | python3 -m json.tool
kubectl get node "$NODE" -o jsonpath='{.spec.taints}' | python3 -m json.tool

echo
echo "All done. Box should be back in gaming mode, taint reapplied."
