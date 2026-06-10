#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

svc sunshine-qos.service active
nft_table_exists inet sunshine_qos
sudo nft list table inet sunshine_qos 2>/dev/null | grep -q 'dscp set af41' \
  && ok "DSCP AF41 rule present" || fail "DSCP rule missing from sunshine_qos"

iface=$(ip -o -4 route show default | awk '{print $5; exit}')
sudo ethtool "$iface" 2>/dev/null | grep -q 'Wake-on: g' \
  && ok "WOL armed on $iface" || warn "WOL not armed on $iface (BIOS-side check)"
