#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

[ -x /usr/local/sbin/gpu-profile ] && ok "gpu-profile script installed" || fail "gpu-profile missing"
# v4.0: PL = card max (queried at runtime), no clock lock; modes differ only in compute mode.
grep -q 'power.max_limit' /usr/local/sbin/gpu-profile \
  && ok "PL derived from card max (v4.0)" \
  || fail "gpu-profile hardcodes a power limit — pre-v4.0"
grep -q 'nvidia-smi -lgc' /usr/local/sbin/gpu-profile \
  && fail "gpu-profile still locks clocks (-lgc) — pre-v4.0" \
  || ok "no clock lock (v4.0)"
[ -x /usr/local/sbin/gpu-offsets ] && grep -q 'gpu-offsets' /usr/local/sbin/gpu-profile \
  && ok "VF offsets applied via gpu-offsets (v4.1)" \
  || fail "gpu-offsets missing or not used by gpu-profile — pre-v4.1"
grep -q 'compute) apply EXCLUSIVE_PROCESS' /usr/local/sbin/gpu-profile \
  && ok "compute: EXCLUSIVE_PROCESS set" \
  || fail "compute: missing EXCLUSIVE_PROCESS"
grep -q 'gaming)  apply DEFAULT' /usr/local/sbin/gpu-profile \
  && ok "gaming: DEFAULT compute mode" \
  || fail "gaming: not DEFAULT"
grep -q 'svc_active("gamescope-headless")' /opt/gaming-agent/agent.py \
  && ok "agent.current_mode() uses gamescope service state (v2.5+)" \
  || fail "agent.current_mode() still uses compute_mode flag — needs v2.5+ update"

svc gpu-profile.service enabled
svc gpu-gaming.service  enabled

# After boot: gaming mode should be active (gpu-gaming flips after gpu-profile)
read -r pl plmax mode < <(nvidia-smi --query-gpu=power.limit,power.max_limit,compute_mode --format=csv,noheader,nounits 2>/dev/null | tr -d ',')
[ "${pl:-x}" = "${plmax:-y}" ] && [ "${mode:-}" = "Default" ] \
  && ok "GPU in gaming mode (PL=${pl}W = card max, Default; $(gpu-offsets 2>/dev/null))" \
  || warn "GPU not yet in gaming mode (PL=${pl:-?}/${plmax:-?}, ${mode:-?}) — run after gpu-gaming.service has fired"

# Persistent telemetry (v2.3+) for Xid forensics
svc gpu-telemetry.service enabled
[ -s /var/log/gpu-telemetry.log ] \
  && ok "gpu-telemetry log present ($(wc -l < /var/log/gpu-telemetry.log) lines)" \
  || warn "gpu-telemetry.log empty — service may not have started yet"
