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

# Idle auto-suspend keys off streaming_active, so it must track the live stream.
/opt/gaming-agent/idle-check.sh --self-test >/dev/null && ok "idle-check decision self-test passes" || fail "idle-check self-test fails"
jgid=$(getent group systemd-journal | cut -d: -f3)
grep -qw "$jgid" <<<"$(awk '/^Groups:/{$1=""; print}' "/proc/$(systemctl show -p MainPID --value gaming-agent)/status")" \
  && ok "agent can read Sunshine's journal (systemd-journal)" || fail "agent lacks systemd-journal (streaming_active would always be false)"
inv=$(systemctl show -p InvocationID --value sunshine)
last=$(sudo journalctl _SYSTEMD_INVOCATION_ID="$inv" -o cat --no-pager -g 'CLIENT (CONNECTED|DISCONNECTED)' -n 1 2>/dev/null || true)
want=false; [[ "$last" == *"CLIENT CONNECTED" ]] && want=true
got=$(echo "$status" | jq -r .streaming_active)
[ "$got" = "$want" ] && ok "streaming_active=$got matches Sunshine's last client event" || fail "streaming_active=$got but Sunshine's last event says $want"
