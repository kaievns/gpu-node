#!/usr/bin/env bash
# cluster/50-alerts — 5 Grafana alert rules + notification policy fix.
# Runs the existing apply.py which talks to the Grafana provisioning API.
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

require kubectl python3

# pyyaml is a dependency of apply.py. PEP 668: modern distro pythons are
# "externally managed" — bare pip refuses to install. Prefer the system
# package, fall back to pip --user (and --break-system-packages only as a
# loud last resort).
if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "  installing pyyaml"
  if command -v pacman >/dev/null 2>&1; then
    sudo pacman -S --needed --noconfirm python-yaml
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get install -y python3-yaml
  elif python3 -m pip install --quiet --user pyyaml 2>/dev/null; then
    :
  else
    warn "pip refused (PEP 668 externally-managed env) — overriding with --break-system-packages (user site only)"
    python3 -m pip install --quiet --user --break-system-packages pyyaml
  fi
  python3 -c 'import yaml' 2>/dev/null \
    || die "pyyaml still missing — install it yourself (pacman -S python-yaml / apt install python3-yaml) and re-run"
fi

python3 "$REPO_ROOT/cluster/monitoring/alerting/apply.py"

ok "Grafana alert rules + notification policy applied"
