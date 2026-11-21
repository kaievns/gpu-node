#!/usr/bin/env bash
# host/85-gaming-agent — FastAPI HTTP control plane on :8080 + idle-check timer.
# Installs the bearer token from .env; cluster/30-controller reads the same file.
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

ensure_pkg python-fastapi uvicorn jq

# system user (no home, no shell)
id -u gaming-agent >/dev/null 2>&1 \
  || sudo useradd -r -s /usr/sbin/nologin -d /opt/gaming-agent -M gaming-agent

# Token: .env is the source. Write it only when the host copy differs.
require_agent_token
token_changed=0
sudo install -d /etc/gaming-agent
if agent_token_stale /etc/gaming-agent/token; then
  echo "  installing agent token from .env"
  printf '%s\n' "$AGENT_TOKEN" | sudo install -m 0640 -o root -g gaming-agent /dev/stdin /etc/gaming-agent/token
  token_changed=1
fi
sudo chown root:gaming-agent /etc/gaming-agent/token
sudo chmod 640 /etc/gaming-agent/token

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
# The agent reads the token once, at start.
[ "$token_changed" -eq 0 ] || sudo systemctl restart gaming-agent.service

ok "gaming-agent installed"
