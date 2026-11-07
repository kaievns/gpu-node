#!/usr/bin/env bash
# host/80-gaming-stack — gamescope-headless + Sunshine + disconnect watchdog
# + udev uinput rule + Sunshine config for $GAME_USER.
#
# NOTE: gamescope-revert.sh and gs-safe-ondisk.sh were deliberately dropped
# from the payload (broken — referenced deleted units / out-of-repo backups).
# Don't reintroduce them.
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

GAME_USER=gamer  # fixed: units hardcode gamer / uid 1100

ensure_pkg gamescope xorg-xwayland seatd libmysofa
pacman -Qq sunshine >/dev/null 2>&1 || ensure_aur_pkg sunshine

# launcher script (sets HDR env, shader cache, PULSE_SINK=Surround_HRTF, etc.)
install_file 0755 root:root usr/local/bin/gamescope-headless.sh /usr/local/bin/gamescope-headless.sh

# disconnect-teardown helper
install_file 0755 root:root usr/local/sbin/kill-running-game.sh /usr/local/sbin/kill-running-game.sh
install_file 0755 root:root usr/local/sbin/stream-res /usr/local/sbin/stream-res
install_file 0755 root:root usr/local/bin/stream-mode /usr/local/bin/stream-mode
install_file 0755 root:root usr/local/bin/stream-hdr /usr/local/bin/stream-hdr
install_file 0644 root:root etc/gamescope/scripts/50-stream-hdr.lua /etc/gamescope/scripts/50-stream-hdr.lua
sudo rm -f /etc/tmpfiles.d/gamescope-headless.conf  # old rule that cleared stream-res pins at boot

# units + drop-ins
install_file 0644 root:root etc/systemd/system/gamescope-headless.service       /etc/systemd/system/gamescope-headless.service
install_file 0644 root:root etc/systemd/system/sunshine.service                 /etc/systemd/system/sunshine.service
install_file 0644 root:root etc/systemd/system/sunshine-disconnect-watchdog.service /etc/systemd/system/sunshine-disconnect-watchdog.service
[ -d "$PAYLOAD_DIR/etc/systemd/system/gamescope-headless.service.d" ] \
  && install_dir etc/systemd/system/gamescope-headless.service.d /etc/systemd/system/gamescope-headless.service.d
[ -d "$PAYLOAD_DIR/etc/systemd/system/sunshine.service.d" ] \
  && install_dir etc/systemd/system/sunshine.service.d /etc/systemd/system/sunshine.service.d
install_dir etc/systemd/system/user-1100.slice.d /etc/systemd/system/user-1100.slice.d
install_file 0644 root:root etc/nftables.d/game-fence.nft /etc/nftables.d/game-fence.nft
install_file 0644 root:root etc/systemd/system/game-fence-nft.service /etc/systemd/system/game-fence-nft.service
install_file 0644 root:root etc/polkit-1/rules.d/50-game-fence.rules /etc/polkit-1/rules.d/50-game-fence.rules

# udev rule — gives /dev/uinput perms to Sunshine for virtual gamepad
install_file 0644 root:root etc/udev/rules.d/99-uinput.rules /etc/udev/rules.d/99-uinput.rules
install_file 0644 root:root etc/udev/rules.d/99-gamer-gamepads.rules /etc/udev/rules.d/99-gamer-gamepads.rules
sudo udevadm control --reload && sudo udevadm trigger /dev/uinput 2>/dev/null || true
sudo udevadm trigger --subsystem-match=input --action=change

# Sunshine config in the gamer home.
sudo -u "$GAME_USER" install -d "/home/$GAME_USER/.config/sunshine"
sudo install -m 0644 -o "$GAME_USER" -g "$GAME_USER" \
  "$PAYLOAD_DIR/home/gamer/.config/sunshine/sunshine.conf" "/home/$GAME_USER/.config/sunshine/sunshine.conf"
sudo install -m 0644 -o "$GAME_USER" -g "$GAME_USER" \
  "$PAYLOAD_DIR/home/gamer/.config/sunshine/apps.json"     "/home/$GAME_USER/.config/sunshine/apps.json"

sudo systemctl daemon-reload
sudo systemctl enable game-fence-nft.service gamescope-headless.service sunshine.service sunshine-disconnect-watchdog.service
sudo systemctl start gamescope-headless.service sunshine-disconnect-watchdog.service

warn "Sunshine pairing state NOT restored (sunshine_state.json is never in the repo) — pair the deck fresh at https://172.16.1.220:47990"
ok "gaming stack installed"
