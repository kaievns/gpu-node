#!/usr/bin/env bash
# host/40-nvidia — nvidia-open + nvidia-container-toolkit + persistenced.
# Packages installed in host/10; this section wires services + CDI.
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

ensure_pkg nvidia-open nvidia-container-toolkit

# persistence mode (keeps driver loaded across CUDA context cycles)
sudo systemctl enable --now nvidia-persistenced.service

# Regenerate the CDI spec (CDI = container device interface; nvidia-ctk
# emits /etc/cdi/nvidia.yaml so containerd/runtime can hand the GPU to
# pods without device-plugin allocation when NVIDIA_VISIBLE_DEVICES=all)
if command -v nvidia-ctk >/dev/null; then
  sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml >/dev/null
fi

ok "nvidia configured"
