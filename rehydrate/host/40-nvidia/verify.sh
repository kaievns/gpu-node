#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

nvidia-smi --query-gpu=name,driver_version --format=csv,noheader,nounits 2>/dev/null \
  | grep -q 'NVIDIA GeForce' && ok "nvidia-smi sees $(nvidia-smi --query-gpu=name --format=csv,noheader)" || fail "nvidia-smi not working"

[ -x /usr/bin/nvidia-container-runtime ] && ok "nvidia-container-runtime present" || fail "nvidia-container-runtime missing"
[ -f /etc/cdi/nvidia.yaml ] && ok "/etc/cdi/nvidia.yaml generated" || warn "no CDI spec — pods using NVIDIA_VISIBLE_DEVICES won't work"

svc nvidia-persistenced.service active
