#!/usr/bin/env bash
# scripts/sync-from-host.sh — pull the live host's config INTO the tracked
# host/ tree, so `git diff host/` (or the status printed at the end) shows
# exactly how the box has drifted from what's in git.
#
# Replaces the old backup/meta/sync.sh, which synced into the gitignored
# backup/ attic and used `rsync -R` for the systemd drop-in dirs — that
# nested etc/systemd/system/X.service.d/etc/systemd/system/X.service.d/...
# duplicates into the tree. Fixed here: plain `rsync -az` per file/dir with
# explicit destination paths, no -R anywhere.
#
# Deliberately NOT pulled into host/:
#   - /etc/gaming-agent/token — secret. Regenerate on restore:
#       openssl rand -hex 32 | sudo tee /etc/gaming-agent/token
#     and update the matching k8s Secret (gpu-node-controller-secret).
#   - ~/.config/sunshine/sunshine_state.json — Sunshine creds + client
#     pairings. Never in git; pair fresh on restore.
#   - HRTF binaries (MIT_KEMAR_normal_pinna.sofa, oal+++.wav, ir_*.wav) —
#     not git material; ir_*.wav are derived from oal+++.wav at install time
#     (recipe in docs/audio.md). Originals live in the gitignored backup/.
#   - gpu-profile.service.d/ — vestigial coolbits drop-in pair, net effect 0.
#   - gamescope-revert.sh, gs-safe-ondisk.sh, steamdeck-edid-revert.sh —
#     broken/stale escape hatches referencing deleted units.
#
# Meta capture:
#   - pacman package lists → host/meta/ (tracked) AND backup/meta/ (attic).
#   - system-info.txt + last-sync.txt → backup/meta/ only (machine-identity
#     and per-run churn; gitignored on purpose).
#
# Requires: SSH key auth to the box with NOPASSWD sudo (for `sudo rsync`).
# Target override: SYNC_HOST=user@ip ./sync-from-host.sh
set -euo pipefail

HOST="${SYNC_HOST:-kai@172.16.1.220}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST_TREE="$REPO_ROOT/host"
BACKUP_META="$REPO_ROOT/backup/meta"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
# -s (--protect-args): remote paths pass verbatim, no remote-shell word
# splitting if a manifest entry ever grows a space.
RSYNC_OPTS=(-azs --timeout=20 --rsync-path='sudo rsync'
            -e "ssh ${SSH_OPTS[*]}")

# Failure accounting (bash-3.2-safe: no empty-array expansion under set -u).
FAILED_COUNT=0
FAILED_PATHS=""
note_failure() {
  echo "  !! FAILED: $1" >&2
  FAILED_COUNT=$((FAILED_COUNT + 1))
  FAILED_PATHS="${FAILED_PATHS}  $1"$'\n'
}

# pull <path-relative-to-/> — copy one file from the host to the identical
# path under host/. Explicit destination, parent dirs pre-created (no -R).
pull() {
  local rel="$1" dest="$HOST_TREE/$1"
  mkdir -p "$(dirname "$dest")"
  rsync "${RSYNC_OPTS[@]}" "$HOST:/$rel" "$dest" || note_failure "/$rel"
}

# pull_dir <dir-relative-to-/> — sync a whole directory tree. --delete so
# drop-ins removed on the host show up as deletions in git status.
# --exclude=etc/ refuses to re-import any leftover nested
# etc/systemd/... artifacts of the old -R bug, should they exist host-side.
pull_dir() {
  local rel="$1" dest="$HOST_TREE/$1"
  mkdir -p "$dest"
  rsync "${RSYNC_OPTS[@]}" --delete --exclude='etc/' \
    "$HOST:/$rel/" "$dest/" || note_failure "/$rel/"
}

# ── manifest: files tracked in host/, paths relative to / ────────────────
FILES=(
  # bootloader + kernel cmdline (EDID injection, nvidia_drm.modeset, resume=)
  boot/loader/loader.conf
  boot/loader/entries/arch.conf

  # nftables QoS for Sunshine UDP egress (DSCP AF41)
  etc/nftables.d/sunshine-qos.nft

  # audio: PipeWire filter-chain configs (HRTF binaries deliberately absent)
  etc/pipewire/pipewire.conf.d/90-hrtf-surround.conf
  etc/pipewire/pipewire.conf.d/91-hesuvi-surround.conf

  # CoolerControl curves (watercurve on rad fans; pump pinned 100%)
  etc/coolercontrol/config.toml

  # k3s agent
  etc/rancher/k3s/config.yaml
  etc/rancher/k3s/registries.yaml

  # gaming-agent — host side of the mode-flip controller
  etc/sudoers.d/gaming-agent
  etc/systemd/system/gaming-agent.service
  etc/systemd/system/gpu-idle-check.service
  etc/systemd/system/gpu-idle-check.timer
  opt/gaming-agent/agent.py
  opt/gaming-agent/idle-check.sh

  # gamescope + sunshine + watchdog + qos units
  etc/systemd/system/gamescope-headless.service
  etc/systemd/system/sunshine.service
  etc/systemd/system/sunshine-disconnect-watchdog.service
  etc/systemd/system/sunshine-qos.service

  # gpu-profile boot ordering / gaming-mode override
  etc/systemd/system/gpu-profile.service
  etc/systemd/system/gpu-gaming.service

  # 1 Hz GPU telemetry for Xid forensics (all three were missing from the
  # old sync.sh manifest)
  etc/systemd/system/gpu-telemetry.service
  etc/logrotate.d/gpu-telemetry
  usr/local/sbin/gpu-telemetry.sh

  # uinput perms (Sunshine virtual gamepad)
  etc/udev/rules.d/99-uinput.rules

  # Steam Deck EDID injected via kernel cmdline
  usr/lib/firmware/edid/steamdeck.bin

  # scripts
  usr/local/bin/gamescope-headless.sh
  usr/local/sbin/gpu-profile
  usr/local/sbin/kill-running-game.sh

  # Sunshine config (sunshine_state.json deliberately not listed)
  home/kai/.config/sunshine/sunshine.conf
  home/kai/.config/sunshine/apps.json
)

# systemd drop-in dirs synced whole (gpu-profile.service.d intentionally
# absent — vestigial, see header)
DROPIN_DIRS=(
  etc/systemd/system/gamescope-headless.service.d
  etc/systemd/system/sunshine.service.d
)

echo "═══ [1/4] sync ${#FILES[@]} files from $HOST → host/ ═══"
for f in "${FILES[@]}"; do
  pull "$f"
done

echo "═══ [2/4] sync systemd drop-in dirs ═══"
for d in "${DROPIN_DIRS[@]}"; do
  echo "  → /$d/"
  pull_dir "$d"
done

echo "═══ [3/4] package lists → host/meta/ (tracked) + backup/meta/ ═══"
mkdir -p "$HOST_TREE/meta" "$BACKUP_META"
# Write via temp files: `ssh > tracked-file` truncates the tracked list
# BEFORE ssh runs, so a connection failure would leave it empty.
plist=$(mktemp)
ssh "${SSH_OPTS[@]}" "$HOST" 'pacman -Qqe' > "$plist" && mv "$plist" "$HOST_TREE/meta/packages-explicit.list"
alist=$(mktemp)
# pacman -Qqm exits 1 when there are no foreign packages — only tolerate that
# case (output empty + exit 1), not ssh/connection failures (exit 255).
rc=0
ssh "${SSH_OPTS[@]}" "$HOST" 'pacman -Qqm' > "$alist" || rc=$?
if [ "$rc" -eq 0 ] || { [ "$rc" -eq 1 ] && [ ! -s "$alist" ]; }; then
  mv "$alist" "$HOST_TREE/meta/packages-aur.list"
else
  rm -f "$alist"; note_failure "pacman -Qqm over ssh (exit $rc)"
fi
qlist=$(mktemp)
ssh "${SSH_OPTS[@]}" "$HOST" 'pacman -Qq' > "$qlist" && mv "$qlist" "$HOST_TREE/meta/packages-all.list"
cp "$HOST_TREE/meta/"packages-*.list "$BACKUP_META/"
echo "  explicit: $(wc -l < "$HOST_TREE/meta/packages-explicit.list") pkgs," \
     "AUR: $(wc -l < "$HOST_TREE/meta/packages-aur.list") pkgs"

echo "═══ [4/4] system metadata → backup/meta/ (gitignored) ═══"
ssh "${SSH_OPTS[@]}" "$HOST" 'set -e
  echo "── uname ──";          uname -a
  echo
  echo "── /proc/cmdline ──";  cat /proc/cmdline
  echo
  echo "── lsblk ──";          lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,UUID
  echo
  echo "── hostnamectl ──";    hostnamectl
  echo
  echo "── nvidia-smi ──";     nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv
  echo
  echo "── systemctl is-enabled (custom services) ──"
  for u in gpu-profile gpu-gaming gpu-telemetry gamescope-headless sunshine \
           sunshine-disconnect-watchdog sunshine-qos gaming-agent \
           gpu-idle-check.timer k3s-agent coolercontrold; do
    printf "%-40s %s\n" "$u" "$(systemctl is-enabled $u 2>&1)"
  done
  echo
  echo "── bootctl status ──"; bootctl status 2>&1 | head -30
' > "$BACKUP_META/system-info.txt"
date -u +'%Y-%m-%dT%H:%M:%SZ' > "$BACKUP_META/last-sync.txt"

echo
echo "═══ drift vs git (empty = host matches repo) ═══"
git -C "$REPO_ROOT" status --short -- host/

if [ "$FAILED_COUNT" -gt 0 ]; then
  echo
  echo "!! $FAILED_COUNT path(s) failed to sync:" >&2
  printf '%s' "$FAILED_PATHS" >&2
  exit 1
fi
