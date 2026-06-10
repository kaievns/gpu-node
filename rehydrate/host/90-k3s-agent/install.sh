#!/usr/bin/env bash
# host/90-k3s-agent — install k3s agent + apply node config + registries.yaml.
#
# Requires env vars (or interactive prompt):
#   K3S_URL    : e.g. https://172.16.1.1:6443
#   K3S_TOKEN  : node-token from control plane (cat /var/lib/rancher/k3s/server/node-token)
#   K3S_VERSION (optional, defaults to v1.33.7+k3s3 to match the cluster)
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

K3S_URL="${K3S_URL:-}"
K3S_TOKEN="${K3S_TOKEN:-}"
K3S_VERSION="${K3S_VERSION:-v1.33.7+k3s3}"

if [ -z "$K3S_URL" ]; then
  read -r -p "K3S_URL (e.g. https://172.16.1.1:6443): " K3S_URL
fi
if [ -z "$K3S_TOKEN" ]; then
  read -r -s -p "K3S_TOKEN: " K3S_TOKEN; echo
fi
[ -n "$K3S_URL" ] && [ -n "$K3S_TOKEN" ] || die "K3S_URL + K3S_TOKEN required"

# node config — taints + labels + node-name. Must exist BEFORE first agent start.
install_file 0644 root:root etc/rancher/k3s/config.yaml      /etc/rancher/k3s/config.yaml
install_file 0644 root:root etc/rancher/k3s/registries.yaml  /etc/rancher/k3s/registries.yaml

# k3s 1.33 auto-detects nvidia + nvidia-cdi runtimes — DO NOT write a
# containerd config.toml.tmpl (we tried; it duplicates and triggers restart loops).

# `systemctl cat` instead of list-unit-files|grep -q: grep -q's early exit
# can SIGPIPE systemctl under pipefail, mis-reading an installed box as fresh.
if ! systemctl cat k3s-agent.service >/dev/null 2>&1; then
  echo "  installing k3s agent ($K3S_VERSION)"
  curl -sfL https://get.k3s.io | \
    K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" INSTALL_K3S_VERSION="$K3S_VERSION" \
    sh -s - agent
else
  warn "k3s-agent already installed; restarting to pick up config"
  sudo systemctl restart k3s-agent
fi

ok "k3s agent installed + joined"
