#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

svc coolercontrold.service active

# The two hwmon chips driving the loop should be present.
for chip in asusec nct6798; do
  sensors 2>/dev/null | grep -qi "^$chip" && ok "sensors sees $chip" || fail "sensors missing $chip"
done

# Pump (nct6798 fan5) should be spinning. ~2700 RPM expected.
pump_rpm=$(sensors -u nct6798-isa-* 2>/dev/null | awk '/fan5_input/ {print int($2); exit}')
[ "${pump_rpm:-0}" -gt 1500 ] && ok "pump RPM $pump_rpm (>1500)" || fail "pump RPM low/missing ($pump_rpm)"

# Coolant temp (asusec temp4) should be readable.
water=$(sensors -u asusec-isa-* 2>/dev/null | awk '/temp4_input/ {print int($2); exit}')
[ "${water:-0}" -gt 0 ] && ok "coolant temp ${water}°C" || warn "coolant temp not readable"
