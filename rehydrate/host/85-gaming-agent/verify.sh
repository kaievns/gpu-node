#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

svc gaming-agent.service active
svc gpu-idle-check.timer  active

# token exists, has correct perms
[ -s /etc/gaming-agent/token ] && ok "agent token present" || fail "agent token missing"
[ "$(stat -c%a /etc/gaming-agent/token)" = "640" ] && ok "token mode 640" || fail "token mode wrong"

# Agent /status responds with valid token
TOKEN=$(sudo cat /etc/gaming-agent/token)
status=$(curl -fsS -m 5 -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8080/status)
echo "$status" | grep -q '"mode"' && ok "agent /status responding" || fail "agent /status broken"

# /status includes streaming_active field (gaming-preempts-compute gate)
echo "$status" | grep -q '"streaming_active"' \
  && ok "/status exposes streaming_active" \
  || fail "/status missing streaming_active — agent.py is pre-fix"

# Wrong token → 403
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer bad" http://127.0.0.1:8080/status)
[ "$code" = "403" ] && ok "agent rejects bad tokens" || fail "agent auth check failed (got $code)"
