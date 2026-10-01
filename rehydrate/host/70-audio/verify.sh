#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

GAME_USER=gamer  # fixed: units hardcode gamer / uid 1100

# SOFA is a historical artifact (no live conf loads it) — warn, don't gate.
[ -f /etc/pipewire/hrtf/MIT_KEMAR_normal_pinna.sofa ] && ok "MIT KEMAR SOFA present" || warn "SOFA missing (only needed to reproduce the v1–v4 iteration log)"
[ -f "/etc/pipewire/hrtf/hesuvi/oal+++.wav" ]         && ok "HeSuVi oal+++ source present" || fail "HeSuVi source missing"

# Check all 14 split IRs
count=$(ls /etc/pipewire/hrtf/hesuvi/ir_*.wav 2>/dev/null | wc -l)
[ "$count" -eq 14 ] && ok "14 HeSuVi mono IRs present" || fail "expected 14 ir_*.wav, got $count"

# PipeWire user services ($GAME_USER)
as_user() {
  # `env` carries the var explicitly — sudo's env_reset rejects bare VAR=x
  # assignments on the command line without a SETENV tag.
  sudo -u "$GAME_USER" env XDG_RUNTIME_DIR="/run/user/$(id -u "$GAME_USER")" "$@"
}
as_user systemctl --user is-active pipewire >/dev/null 2>&1 \
  && ok "pipewire running for $GAME_USER" || warn "pipewire not running for $GAME_USER"

# Filter-chain sinks (one dump: grep -q on a live pipe trips pipefail via SIGPIPE)
dump=$(as_user pw-dump 2>/dev/null || true)
for sink in BinauralBus Surround_HeSuVi Surround_HRTF; do
  grep -qE "\"node\\.name\":\\s*\"$sink\"" <<<"$dump" && ok "$sink sink loaded" || fail "$sink sink missing"
done
