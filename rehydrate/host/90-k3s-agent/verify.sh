#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

svc k3s-agent.service active
svc k3s-agent.service enabled

# config.yaml has our node name + taints
grep -q '^node-name: "gpu-node"' /etc/rancher/k3s/config.yaml && ok "node-name=gpu-node" || fail "node-name wrong"
grep -q 'gpu=true:NoSchedule'   /etc/rancher/k3s/config.yaml && ok "gpu taint configured" || fail "gpu taint missing"

# registries.yaml has the HTTP registry mirror
grep -q 'http://172.16.1.89/v2' /etc/rancher/k3s/registries.yaml \
  && ok "registry.homelab HTTP mirror configured" || fail "registries.yaml missing the homelab mirror"

# k3s auto-detected nvidia runtimes
sudo journalctl -u k3s-agent --no-pager 2>/dev/null | grep -q 'Found nvidia container runtime' \
  && ok "k3s auto-detected nvidia runtime" || warn "no nvidia auto-detect log (yet?)"
