#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

NODE_USER="${NODE_USER:-kai}"

# SOFA is a historical artifact (no live conf loads it) — warn, don't gate.
[ -f /etc/pipewire/hrtf/MIT_KEMAR_normal_pinna.sofa ] && ok "MIT KEMAR SOFA present" || warn "SOFA missing (only needed to reproduce the v1–v4 iteration log)"
[ -f "/etc/pipewire/hrtf/hesuvi/oal+++.wav" ]         && ok "HeSuVi oal+++ source present" || fail "HeSuVi source missing"

# Check all 14 split IRs
count=$(ls /etc/pipewire/hrtf/hesuvi/ir_*.wav 2>/dev/null | wc -l)
[ "$count" -eq 14 ] && ok "14 HeSuVi mono IRs present" || fail "expected 14 ir_*.wav, got $count"

# PipeWire user services ($NODE_USER)
as_user() {
  # `env` carries the var explicitly — sudo's env_reset rejects bare VAR=x
  # assignments on the command line without a SETENV tag.
  sudo -u "$NODE_USER" env XDG_RUNTIME_DIR="/run/user/$(id -u "$NODE_USER")" "$@"
}
as_user systemctl --user is-active pipewire >/dev/null 2>&1 \
  && ok "pipewire running for $NODE_USER" || warn "pipewire not running for $NODE_USER"

# Filter-chain sinks
as_user pw-dump 2>/dev/null \
  | grep -qE '"node\.name":\s*"BinauralBus"' \
  && ok "BinauralBus sink loaded" || fail "BinauralBus sink missing"
as_user pw-dump 2>/dev/null \
  | grep -qE '"node\.name":\s*"Surround_HeSuVi"' \
  && ok "Surround_HeSuVi sink loaded" || fail "Surround_HeSuVi sink missing"
as_user pw-dump 2>/dev/null \
  | grep -qE '"node\.name":\s*"Surround_HRTF"' \
  && ok "Surround_HRTF sink loaded" || fail "Surround_HRTF sink missing (PULSE_SINK target of gamescope-headless.sh)"
