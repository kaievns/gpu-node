#!/usr/bin/env bash
# rehydrate/rehydrate.sh — orchestrator
#
# Usage:
#   ./rehydrate.sh <host|cluster> [install|verify]
#
# - `host`    : runs all rehydrate/host/NN/<step>.sh in order (run on gpu-node)
# - `cluster` : runs all rehydrate/cluster/NN/<step>.sh in order (run from kubectl machine)
# - second arg defaults to "install" then "verify" (both, in that order)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
. "$ROOT/lib/common.sh"

side="${1:-}"
step="${2:-both}"

case "$side" in
  host|cluster) ;;
  *) die "usage: $0 <host|cluster> [install|verify|both]";;
esac

run_step() {
  local s="$1"   # install or verify
  local d
  for d in "$ROOT/$side"/[0-9]*; do
    [ -d "$d" ] || continue
    local script="$d/$s.sh"
    [ -f "$script" ] || { warn "missing $script — skipping"; continue; }
    section "$side / $(basename "$d") / $s"
    (cd "$d" && bash "$script")
  done
}

case "$step" in
  install) run_step install ;;
  verify)  run_step verify  ;;
  both)    run_step install; run_step verify ;;
  *)       die "unknown step: $step (expected install|verify|both)";;
esac

echo
ok "rehydrate $side $step — done"
