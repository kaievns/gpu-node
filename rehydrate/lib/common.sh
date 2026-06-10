# shellcheck shell=bash
# Shared helpers for rehydrate/*/install.sh and verify.sh.
#
# Sourced via:
#   . "$(dirname "$0")/../../lib/common.sh"
#
# Exposes:
#   $REPO_ROOT, $REHYDRATE_DIR, $PAYLOAD_DIR
#   section <title>            — print a section header
#   ok <msg>                   — green [OK] line
#   fail <msg>                 — red  [FAIL] line + exit 1 (use in verify.sh)
#   warn <msg>                 — yellow [WARN] line, non-fatal
#   die <msg>                  — error + exit 1 (install.sh)
#   require <cmd>...           — exit if <cmd> not in PATH
#   ensure_pkg <pkg>...        — pacman install if missing
#   ensure_aur_pkg <pkg>...    — yay install if missing (needs yay already)
#   install_file <mode> <owner:group> <src-relative-to-payload> <target>
#                              — sudo install -m MODE -o OWN -g GRP $PAYLOAD_DIR/<src> <target>
#   install_dir <src-dir> <target-dir>
#                              — sudo cp -aT of a payload subtree
#   svc <unit> active|enabled  — short systemctl status check, exits 1 if not
#   nft_table_exists <name>    — verify nft table is loaded
set -euo pipefail

# Resolve repo paths regardless of where the calling script lives.
__src="${BASH_SOURCE[0]}"
REHYDRATE_DIR="$(cd "$(dirname "$__src")/.." && pwd)"
REPO_ROOT="$(cd "$REHYDRATE_DIR/.." && pwd)"
# host/ is the tracked, curated host-config payload (filesystem-mirror layout).
PAYLOAD_DIR="${PAYLOAD_DIR:-$REPO_ROOT/host}"
export REPO_ROOT REHYDRATE_DIR PAYLOAD_DIR

# Colors only if stdout is a TTY.
if [ -t 1 ]; then
  _r=$'\033[31m'; _g=$'\033[32m'; _y=$'\033[33m'; _b=$'\033[34m'; _bold=$'\033[1m'; _z=$'\033[0m'
else
  _r=; _g=; _y=; _b=; _bold=; _z=
fi

section() { printf '\n%s═══ %s ═══%s\n' "$_bold" "$*" "$_z"; }
ok()      { printf '  %s[OK]%s   %s\n' "$_g" "$_z" "$*"; }
warn()    { printf '  %s[WARN]%s %s\n' "$_y" "$_z" "$*"; }
fail()    { printf '  %s[FAIL]%s %s\n' "$_r" "$_z" "$*" >&2; exit 1; }
die()     { printf '  %s[ERR]%s  %s\n'  "$_r" "$_z" "$*" >&2; exit 1; }

require() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
  done
}

ensure_pkg() {
  local missing=()
  for p in "$@"; do
    pacman -Qq "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    sudo pacman -S --needed --noconfirm "${missing[@]}"
  fi
}

ensure_aur_pkg() {
  command -v yay >/dev/null 2>&1 || die "yay not installed (run host/10-packages first)"
  local missing=()
  for p in "$@"; do
    pacman -Qq "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    yay -S --needed --noconfirm "${missing[@]}"
  fi
}

# install_file MODE OWNER:GROUP SRC-RELATIVE-TO-PAYLOAD TARGET
install_file() {
  local mode="$1" owner="$2" src="$3" target="$4"
  [ -e "$PAYLOAD_DIR/$src" ] || die "missing in host/ payload tree: $src"
  sudo install -D -m "$mode" -o "${owner%:*}" -g "${owner#*:}" \
    "$PAYLOAD_DIR/$src" "$target"
}

# install_dir SRC-DIR (relative to payload) TARGET-DIR (gets contents of SRC-DIR)
install_dir() {
  local src="$1" target="$2"
  [ -d "$PAYLOAD_DIR/$src" ] || die "missing dir in host/ payload tree: $src"
  sudo mkdir -p "$target"
  # cp -a would preserve the repo checkout's (non-root) ownership on files
  # landing in /etc — force root:root like install_file does.
  sudo cp -rT --no-preserve=ownership "$PAYLOAD_DIR/$src" "$target"
  sudo chown -R root:root "$target"
}

svc() {
  local unit="$1" check="$2"
  case "$check" in
    active)  systemctl is-active  --quiet "$unit"  && ok "$unit is active"  || fail "$unit not active";;
    enabled) systemctl is-enabled --quiet "$unit"  && ok "$unit is enabled" || fail "$unit not enabled";;
    *) die "svc: unknown check $check";;
  esac
}

nft_table_exists() {
  sudo nft list table "$1" "$2" >/dev/null 2>&1 \
    && ok "nft table $1 $2 loaded" || fail "nft table $1 $2 not loaded"
}
