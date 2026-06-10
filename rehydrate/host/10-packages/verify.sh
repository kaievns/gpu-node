#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

# Critical packages that everything else depends on.
for p in nvidia-open nvidia-container-toolkit pipewire pipewire-pulse wireplumber \
         python-fastapi uvicorn jq nftables rsync coolercontrold sunshine yay-bin; do
  pacman -Qq "$p" >/dev/null 2>&1 && ok "$p installed" || fail "$p missing"
done
