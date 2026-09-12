#!/usr/bin/env bash
# host/60-gpu-profile — installs gpu-profile v4.0 + persistent telemetry.
# v4.0 (2026-09-12, RTX 5080): PL = card max, no clock lock, perf governor;
#   compute = EXCLUSIVE_PROCESS, gaming = DEFAULT.
# Also installs gpu-telemetry (1Hz nvidia-smi capture for Xid forensics).
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

ensure_pkg logrotate  # needed for gpu-telemetry log rotation

install_file 0755 root:root usr/local/sbin/gpu-profile /usr/local/sbin/gpu-profile
install_file 0644 root:root etc/systemd/system/gpu-profile.service /etc/systemd/system/gpu-profile.service
install_file 0644 root:root etc/systemd/system/gpu-gaming.service  /etc/systemd/system/gpu-gaming.service

# NOTE: the live box has a vestigial gpu-profile.service.d/ drop-in pair
# (10-coolbits + 10-no-coolbits, net effect zero). Deliberately NOT in the
# host/ payload and NOT recreated here.

# Persistent telemetry — 1Hz nvidia-smi log to /var/log/gpu-telemetry.log
install_file 0755 root:root usr/local/sbin/gpu-telemetry.sh        /usr/local/sbin/gpu-telemetry.sh
install_file 0644 root:root etc/systemd/system/gpu-telemetry.service /etc/systemd/system/gpu-telemetry.service
install_file 0644 root:root etc/logrotate.d/gpu-telemetry          /etc/logrotate.d/gpu-telemetry

sudo systemctl daemon-reload
sudo systemctl enable gpu-profile.service gpu-gaming.service
sudo systemctl enable --now gpu-telemetry.service
# Don't start gpu-profile/gpu-gaming now — they fire at boot in the right order;
# manually applying compute mode here would conflict with any active CUDA context
# (and NEVER flip to EXCLUSIVE_PROCESS while the gaming stack streams — NVENC dies).

ok "gpu-profile + gpu-telemetry installed (profile services active at next boot)"
