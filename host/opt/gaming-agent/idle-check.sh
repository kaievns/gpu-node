#!/bin/bash
# Run every 5 min by gpu-idle-check.timer; suspends the box after 15 min idle
# in gaming mode (no game running, no GPU util). In compute mode, never sleeps —
# the cluster-side gpu-node-controller manages that lifecycle.
set -euo pipefail

AGENT_URL=http://127.0.0.1:8080
TOKEN=$(cat /etc/gaming-agent/token)
IDLE_FILE=/run/gpu-node-idle-since
IDLE_THRESHOLD=900  # 15 min

reset() { rm -f "$IDLE_FILE"; exit 0; }

# Query agent for state.
status=$(curl -fsS -m 5 -H "Authorization: Bearer $TOKEN" "$AGENT_URL/status") || exit 1
mode=$(echo "$status" | jq -r '.mode')
util=$(echo "$status" | jq -r '.gpu_util_pct')

# Compute mode: never sleep here — controller owns the transition.
if [ "$mode" != "gaming" ]; then reset; fi

# Gaming mode: GPU util > 5% means a game/encoder is doing something.
if [ "$util" -gt 5 ]; then reset; fi

# Idle. Track the time we first saw idle.
[ -f "$IDLE_FILE" ] || { date +%s > "$IDLE_FILE"; exit 0; }
SINCE=$(cat "$IDLE_FILE")
NOW=$(date +%s)
if [ $((NOW - SINCE)) -ge "$IDLE_THRESHOLD" ]; then
  rm -f "$IDLE_FILE"
  logger -t gpu-idle-check "idle ${IDLE_THRESHOLD}s; requesting /sleep"
  curl -fsS -m 10 -X POST -H "Authorization: Bearer $TOKEN" "$AGENT_URL/sleep" > /dev/null
fi
