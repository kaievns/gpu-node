#!/usr/bin/env bash
# host/30-network — nftables sunshine-qos (DSCP AF41 on UDP 47998-48010 egress)
# + WOL ethtool persistence on enp7s0.
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

ensure_pkg nftables ethtool

install_file 0644 root:root etc/nftables.d/sunshine-qos.nft       /etc/nftables.d/sunshine-qos.nft
install_file 0644 root:root etc/systemd/system/sunshine-qos.service /etc/systemd/system/sunshine-qos.service
sudo systemctl daemon-reload
sudo systemctl enable --now sunshine-qos.service

# WOL: arm magic-packet wake on the NIC. Persisted via NetworkManager dispatcher
# is the cleanest, but a one-shot ethtool plus the BIOS setting (ErP=disabled +
# Power On By PCIE=enabled) is what actually matters for cold-WOL.
iface=$(ip -o -4 route show default | awk '{print $5; exit}')
sudo ethtool -s "$iface" wol g 2>/dev/null || warn "ethtool wol failed on $iface (NIC may not support)"

ok "network/QoS installed"
