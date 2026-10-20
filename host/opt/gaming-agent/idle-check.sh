#!/bin/bash
# Run every 5 min by gpu-idle-check.timer; suspends the box after 15 min in
# gaming mode with no Moonlight client streaming. In compute mode, never
# sleeps — the cluster-side gpu-node-controller manages that lifecycle.
# `idle-check.sh --self-test` checks the decision rules.
set -euo pipefail

AGENT_URL=http://127.0.0.1:8080
IDLE_FILE=/run/gpu-node-idle-since
IDLE_THRESHOLD=900  # 15 min
GPU_GUARD=30        # % util that still counts as busy (a game left running)

# status JSON on stdin -> "busy" | "idle"; a missing streaming_active counts as streaming
decide() {
  jq -r --argjson guard "$GPU_GUARD" \
    'if .mode != "gaming" or .streaming_active != false or (.gpu_util_pct // 100) > $guard
     then "busy" else "idle" end'
}

if [ "${1:-}" = --self-test ]; then
  bad=0 n=0
  while read -r want json; do
    n=$((n + 1))
    got=$(decide <<<"$json")
    [ "$got" = "$want" ] || { echo "FAIL $json: want $want, got $got"; bad=$((bad + 1)); }
  done <<'CASES'
busy {"mode":"compute","streaming_active":false,"gpu_util_pct":0}
busy {"mode":"gaming","streaming_active":true,"gpu_util_pct":0}
idle {"mode":"gaming","streaming_active":false,"gpu_util_pct":0}
idle {"mode":"gaming","streaming_active":false,"gpu_util_pct":8}
idle {"mode":"gaming","streaming_active":false,"gpu_util_pct":30}
busy {"mode":"gaming","streaming_active":false,"gpu_util_pct":31}
busy {"mode":"gaming","gpu_util_pct":0}
busy {"mode":"gaming","streaming_active":false}
CASES
  echo "idle-check self-test: $((n - bad))/$n passed"
  exit $((bad > 0))
fi

TOKEN=$(cat /etc/gaming-agent/token)
reset() { rm -f "$IDLE_FILE"; exit 0; }

status=$(curl -fsS -m 5 -H "Authorization: Bearer $TOKEN" "$AGENT_URL/status") || exit 1
[ "$(decide <<<"$status")" = idle ] || reset

# Idle. Track the time we first saw idle.
[ -f "$IDLE_FILE" ] || { date +%s > "$IDLE_FILE"; exit 0; }
SINCE=$(cat "$IDLE_FILE")
NOW=$(date +%s)
if [ $((NOW - SINCE)) -ge "$IDLE_THRESHOLD" ]; then
  rm -f "$IDLE_FILE"
  logger -t gpu-idle-check "idle ${IDLE_THRESHOLD}s; requesting /sleep"
  curl -fsS -m 10 -X POST -H "Authorization: Bearer $TOKEN" "$AGENT_URL/sleep" > /dev/null
fi
