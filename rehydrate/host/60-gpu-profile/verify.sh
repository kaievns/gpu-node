#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

[ -x /usr/local/sbin/gpu-profile ] && ok "gpu-profile script installed" || fail "gpu-profile missing"
# v3.0: post-repad — compute uses PL370 + -lgc 0,2160 + EXCLUSIVE_PROCESS.
compute_body=$(awk '/^  compute\)/,/^    ;;/' /usr/local/sbin/gpu-profile)
echo "$compute_body" | grep -q 'nvidia-smi -pl 370' \
  && ok "compute PL=370W (v3.0 post-repad full power)" \
  || fail "compute PL not 370W — gpu-profile is pre-v3.0"
echo "$compute_body" | grep -q 'nvidia-smi -lgc 0,2160' \
  && ok "compute -lgc 0,2160 (v3.0 boost ceiling lift)" \
  || fail "compute missing -lgc 0,2160"
echo "$compute_body" | grep -q 'nvidia-smi -c EXCLUSIVE_PROCESS' \
  && ok "compute: EXCLUSIVE_PROCESS set" \
  || fail "compute: missing EXCLUSIVE_PROCESS"
awk '/^  gaming\)/,/^    ;;/' /usr/local/sbin/gpu-profile | grep -q 'nvidia-smi -pl 370' \
  && ok "gaming PL=370W (unchanged)" \
  || fail "gaming PL is not 370W"
grep -q 'svc_active("gamescope-headless")' /opt/gaming-agent/agent.py \
  && ok "agent.current_mode() uses gamescope service state (v2.5+)" \
  || fail "agent.current_mode() still uses compute_mode flag — needs v2.5+ update"

svc gpu-profile.service enabled
svc gpu-gaming.service  enabled

# After boot: gaming mode should be active (gpu-gaming flips after gpu-profile)
nvidia-smi --query-gpu=power.limit,compute_mode --format=csv,noheader 2>/dev/null \
  | grep -q '370.00 W, Default' \
  && ok "GPU in gaming mode (PL370 + Default)" \
  || warn "GPU not yet in gaming mode (run after gpu-gaming.service has fired)"

# Persistent telemetry (v2.3+) for Xid forensics
svc gpu-telemetry.service enabled
[ -s /var/log/gpu-telemetry.log ] \
  && ok "gpu-telemetry log present ($(wc -l < /var/log/gpu-telemetry.log) lines)" \
  || warn "gpu-telemetry.log empty — service may not have started yet"
