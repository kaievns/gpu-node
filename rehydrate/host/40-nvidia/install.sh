#!/usr/bin/env bash
# host/40-nvidia — nvidia-open + nvidia-container-toolkit + persistenced.
# Packages installed in host/10; this section wires services + CDI.
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

ensure_pkg nvidia-open nvidia-container-toolkit

# persistence mode (keeps driver loaded across CUDA context cycles)
sudo systemctl enable --now nvidia-persistenced.service

# CDI spec (container device interface): nvidia-cdi-refresh writes
# /var/run/cdi/nvidia.yaml at every boot, so containerd/runtime can hand the
# GPU to pods without device-plugin allocation when NVIDIA_VISIBLE_DEVICES=all
sudo systemctl start nvidia-cdi-refresh.service

ok "nvidia configured"
