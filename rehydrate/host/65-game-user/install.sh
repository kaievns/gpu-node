#!/usr/bin/env bash
# host/65-game-user — unprivileged `gamer` account the gaming stack runs as.
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

install_file 0644 root:root etc/sysusers.d/gamer.conf   /etc/sysusers.d/gamer.conf
install_file 0644 root:root etc/tmpfiles.d/gamer.conf   /etc/tmpfiles.d/gamer.conf
install_file 0644 root:root etc/gaming-fence/resolv.conf /etc/gaming-fence/resolv.conf

sudo systemd-sysusers /etc/sysusers.d/gamer.conf
sudo systemd-tmpfiles --create /etc/tmpfiles.d/gamer.conf
sudo loginctl enable-linger gamer

ok "gamer account ready"
