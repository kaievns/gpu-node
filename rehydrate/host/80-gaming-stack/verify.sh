#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

svc gamescope-headless.service active
svc sunshine.service             active
svc sunshine-disconnect-watchdog.service active

# Sunshine listening on its standard ports
for p in 47984 47989 47990 48010; do
  ss -tlnp 2>/dev/null | grep -q ":$p " && ok "Sunshine listening on $p" || fail "port $p not listening"
done

# HDR + HEVC NVENC confirmed
sudo journalctl -u sunshine --since "5 min ago" --no-pager 2>/dev/null \
  | grep -q 'Found HEVC encoder: hevc_nvenc' \
  && ok "HEVC nvenc encoder ready" \
  || warn "no recent NVENC init log (Sunshine may need a client connect to log encoder)"
