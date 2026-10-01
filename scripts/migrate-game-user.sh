#!/usr/bin/env bash
# scripts/migrate-game-user.sh <from-user> <to-user> — move the gaming data
# (Steam library, Proton prefixes, Sunshine pairing, shader caches, audio
# defaults) between home directories. Run ON the host. Reverse by swapping
# the arguments. Stops the gaming stack; refuses while a client is streaming.
set -euo pipefail

FROM="${1:?usage: $0 <from-user> <to-user>}"
TO="${2:?usage: $0 <from-user> <to-user>}"
SRC="/home/$FROM"
DST="/home/$TO"
id "$TO" >/dev/null || { echo "user $TO does not exist" >&2; exit 1; }

ITEMS=(
  .local/share/Steam
  .local/share/applications
  .local/share/feral-interactive
  .local/share/icons
  .local/share/vulkan
  .local/state/wireplumber
  .config/sunshine
  .config/cef_user_data
  .cache/dxvk
  .cache/nvidia
  .cache/vkd3d-proton
  .cache/protonfixes
  .cache/umu-protonfixes
  .nv
  .pki
  .steam
)

last=$(sudo journalctl -u sunshine -n 400 -o cat --no-pager | grep -E "CLIENT (CONNECTED|DISCONNECTED)" | tail -1 || true)
case "$last" in *"CLIENT CONNECTED"*) echo "a client is streaming; refusing" >&2; exit 1 ;; esac

sudo systemctl stop sunshine-disconnect-watchdog.service sunshine.service gamescope-headless.service

for item in "${ITEMS[@]}"; do
  [ -e "$SRC/$item" ] || [ -L "$SRC/$item" ] || continue
  if [ -e "$DST/$item" ]; then echo "skip $item: already in $DST" >&2; continue; fi
  sudo install -d -o "$TO" -g "$TO" -m 0755 "$(dirname "$DST/$item")"
  sudo mv "$SRC/$item" "$DST/$item"
  echo "moved $item"
done

# Absolute paths Steam and Wine recorded under the old home.
if [ -d "$DST/.steam" ]; then
  for link in "$DST"/.steam/*; do
    [ -L "$link" ] || continue
    target=$(readlink "$link")
    case "$target" in "$SRC"/*) sudo ln -sfn "$DST${target#"$SRC"}" "$link" ;; esac
  done
fi
mapfile -t files < <(sudo find "$DST/.local/share/Steam/config" "$DST/.local/share/Steam/steamapps" \
  "$DST/.steam" -maxdepth 1 -name '*.vdf' 2>/dev/null)
mapfile -t -O "${#files[@]}" files < <(sudo find "$DST/.local/share/Steam/steamapps/compatdata" \
  -mindepth 3 -maxdepth 3 -name '*.reg' 2>/dev/null)
for f in "${files[@]}"; do
  sudo grep -qF -e "/home/$FROM/" -e "\\\\home\\\\$FROM\\\\" "$f" || continue
  sudo sed -i -e "s#/home/$FROM/#/home/$TO/#g" -e "s#\\\\\\\\home\\\\\\\\$FROM\\\\\\\\#\\\\\\\\home\\\\\\\\$TO\\\\\\\\#g" "$f"
  echo "rewrote paths in ${f#"$DST"/}"
done

sudo chown -R "$TO:$TO" "$DST"
echo "done; start the stack with: sudo systemctl start gamescope-headless.service"
