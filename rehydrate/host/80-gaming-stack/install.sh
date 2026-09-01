#!/usr/bin/env bash
# host/80-gaming-stack — gamescope-headless + Sunshine + disconnect watchdog
# + udev uinput rule + Sunshine config for $NODE_USER.
#
# NOTE: gamescope-revert.sh and gs-safe-ondisk.sh were deliberately dropped
# from the payload (broken — referenced deleted units / out-of-repo backups).
# Don't reintroduce them.
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

NODE_USER="${NODE_USER:-kai}"

ensure_pkg gamescope xorg-xwayland seatd libmysofa
pacman -Qq sunshine >/dev/null 2>&1 || ensure_aur_pkg sunshine

# launcher script (sets HDR env, shader cache, PULSE_SINK=Surround_HRTF, etc.)
install_file 0755 root:root usr/local/bin/gamescope-headless.sh /usr/local/bin/gamescope-headless.sh

# disconnect-teardown helper
install_file 0755 root:root usr/local/sbin/kill-running-game.sh /usr/local/sbin/kill-running-game.sh
install_file 0755 root:root usr/local/sbin/stream-res /usr/local/sbin/stream-res

# units + drop-ins
install_file 0644 root:root etc/systemd/system/gamescope-headless.service       /etc/systemd/system/gamescope-headless.service
install_file 0644 root:root etc/systemd/system/sunshine.service                 /etc/systemd/system/sunshine.service
install_file 0644 root:root etc/systemd/system/sunshine-disconnect-watchdog.service /etc/systemd/system/sunshine-disconnect-watchdog.service
[ -d "$PAYLOAD_DIR/etc/systemd/system/gamescope-headless.service.d" ] \
  && install_dir etc/systemd/system/gamescope-headless.service.d /etc/systemd/system/gamescope-headless.service.d
[ -d "$PAYLOAD_DIR/etc/systemd/system/sunshine.service.d" ] \
  && install_dir etc/systemd/system/sunshine.service.d /etc/systemd/system/sunshine.service.d

# udev rule — gives /dev/uinput perms to Sunshine for virtual gamepad
install_file 0644 root:root etc/udev/rules.d/99-uinput.rules /etc/udev/rules.d/99-uinput.rules
sudo udevadm control --reload && sudo udevadm trigger /dev/uinput 2>/dev/null || true

# Sunshine config in $NODE_USER's home. Payload path is literally home/kai/
# (the tracked tree mirrors the original box); only the TARGET is parameterized.
sudo -u "$NODE_USER" install -d "/home/$NODE_USER/.config/sunshine"
sudo install -m 0644 -o "$NODE_USER" -g "$NODE_USER" \
  "$PAYLOAD_DIR/home/kai/.config/sunshine/sunshine.conf" "/home/$NODE_USER/.config/sunshine/sunshine.conf"
sudo install -m 0644 -o "$NODE_USER" -g "$NODE_USER" \
  "$PAYLOAD_DIR/home/kai/.config/sunshine/apps.json"     "/home/$NODE_USER/.config/sunshine/apps.json"

sudo systemctl daemon-reload
sudo systemctl enable --now gamescope-headless.service
# sunshine + watchdog pulled in via BindsTo/Wants from gamescope-headless.

warn "Sunshine pairing state NOT restored (sunshine_state.json is never in the repo) — pair the deck fresh at https://172.16.1.220:47990"
ok "gaming stack installed"
