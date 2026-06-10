#!/usr/bin/env bash
# host/85-gaming-agent — FastAPI HTTP control plane on :8080 + idle-check timer.
# Generates a fresh bearer token and stashes it at /tmp/.gpu-node-agent-token
# for cluster/30-controller to pick up.
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

ensure_pkg python-fastapi uvicorn jq

# system user (no home, no shell)
id -u gaming-agent >/dev/null 2>&1 \
  || sudo useradd -r -s /usr/sbin/nologin -d /opt/gaming-agent -M gaming-agent

# Token: reuse existing if present, otherwise generate fresh.
if [ ! -s /etc/gaming-agent/token ]; then
  echo "  generating fresh agent token"
  sudo install -d /etc/gaming-agent
  openssl rand -hex 32 | sudo tee /etc/gaming-agent/token >/dev/null
fi
sudo chown root:gaming-agent /etc/gaming-agent/token
sudo chmod 640 /etc/gaming-agent/token

# Drop token to /tmp for cluster/30-controller to pick up.
# (umask 077; …) so the file is BORN 0600 — a create-then-chmod sequence
# leaves a window where the token sits world-readable in /tmp.
(umask 077; sudo cat /etc/gaming-agent/token > /tmp/.gpu-node-agent-token)

# sudoers (sudo -e syntax-checks via visudo)
install_file 0440 root:root etc/sudoers.d/gaming-agent /etc/sudoers.d/gaming-agent
sudo visudo -c -f /etc/sudoers.d/gaming-agent

# agent + idle-check + units
install_file 0750 gaming-agent:gaming-agent opt/gaming-agent/agent.py      /opt/gaming-agent/agent.py
install_file 0755 root:root                 opt/gaming-agent/idle-check.sh /opt/gaming-agent/idle-check.sh

install_file 0644 root:root etc/systemd/system/gaming-agent.service    /etc/systemd/system/gaming-agent.service
install_file 0644 root:root etc/systemd/system/gpu-idle-check.service  /etc/systemd/system/gpu-idle-check.service
install_file 0644 root:root etc/systemd/system/gpu-idle-check.timer    /etc/systemd/system/gpu-idle-check.timer

sudo systemctl daemon-reload
sudo systemctl enable --now gaming-agent.service gpu-idle-check.timer

ok "gaming-agent installed; token at /tmp/.gpu-node-agent-token"
