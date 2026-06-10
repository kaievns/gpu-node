#!/usr/bin/env bash
# host/50-cooling — CoolerControl + the watercurve config.
# Hardware: nct6798 (CPU_FAN/CHA_FAN/AIO_PUMP) + asusec (T_Sensor on temp4).
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

# coolercontrold is AUR; should be installed by host/10. Confirm.
pacman -Qq coolercontrold >/dev/null 2>&1 || ensure_aur_pkg coolercontrold

# Need acpi_enforce_resources=lax for safe nct6775 PWM writes on ASUS B550.
# Already in our captured boot/loader/entries/arch.conf (host/20 installs it).
grep -q 'acpi_enforce_resources=lax' /proc/cmdline \
  || warn "acpi_enforce_resources=lax not active — reboot after host/20 to enable safe PWM writes"

install_file 0644 root:root etc/coolercontrol/config.toml /etc/coolercontrol/config.toml

sudo systemctl daemon-reload
sudo systemctl enable --now coolercontrold.service

ok "CoolerControl installed (watercurve will apply on next daemon read)"
