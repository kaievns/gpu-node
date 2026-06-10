#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

# Query Grafana via kubectl exec (anonymous-admin)
api() { kubectl -n observability exec deployment/prometheus-stack-grafana -c grafana -- \
        curl -fsS -H "X-WEBAUTH-USER: admin" "http://localhost:3000$1" 2>/dev/null; }

# Folder exists
api '/api/folders' | grep -q '"uid":"gpu-node-alerts"' \
  && ok "folder gpu-node-alerts exists" || fail "folder missing"

# 5 rules with our UIDs exist (gpu-mem-junction-high was removed — dead
# metric on consumer Ampere; see cluster/monitoring/alerting/README.md)
for uid in gpu-pump-rpm-low gpu-coolant-high gpu-temp-high gpu-thermal-violation gpu-xid-error; do
  api '/api/v1/provisioning/alert-rules' | grep -q "\"uid\":\"$uid\"" \
    && ok "rule $uid present" || fail "rule $uid missing"
done

# Notification policy points to Kai Evans (not the default placeholder)
api '/api/v1/provisioning/policies' | grep -q '"receiver":"Kai Evans"' \
  && ok "notification policy routes to Kai Evans" \
  || fail "policy still routing to placeholder — apply.py didn't update"
