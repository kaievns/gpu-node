#!/usr/bin/env bash
# host/70-audio — PipeWire binaural sinks + filter-chain confs.
# Three sinks created: Surround_HeSuVi (HeSuVi IR convolver, priority 3000 =
# system default), BinauralBus (Sunshine's capture point), and Surround_HRTF
# (legacy name: the v5 pure 7.1→stereo ITU downmix, NO HRTF — what games
# actually feed via the PULSE_SINK pin in gamescope-headless.sh).
#
# Binary payloads are NOT in git (size + licensing):
#   - MIT_KEMAR_normal_pinna.sofa → fetched from the libmysofa repo (CC-licensed)
#   - oal+++.wav (HeSuVi HRIR)    → local attic copy or manual download (HeSuVi
#                                    redistribution terms — we don't vendor it)
# The 14 ir_*.wav mono IRs are derived from oal+++.wav at install time (ffmpeg).
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

NODE_USER="${NODE_USER:-kai}"

ensure_pkg pipewire pipewire-pulse wireplumber libmysofa curl

# ── SOFA: fetch if absent ────────────────────────────────────────────────────
SOFA_TARGET=/etc/pipewire/hrtf/MIT_KEMAR_normal_pinna.sofa
SOFA_URL=https://raw.githubusercontent.com/hoene/libmysofa/main/share/MIT_KEMAR_normal_pinna.sofa
# The SOFA file is NOT loaded by any live conf (the HRTF stages were removed
# in v5) — it's kept only so the v1–v4 iteration log in docs/audio.md stays
# reproducible. Download to a temp file first so a mid-transfer failure can't
# leave a truncated file that the -s guard would treat as done forever.
if [ ! -s "$SOFA_TARGET" ]; then
  echo "  fetching MIT KEMAR SOFA from libmysofa upstream"
  tmp=$(mktemp)
  curl -fsSL -o "$tmp" "$SOFA_URL" \
    || { rm -f "$tmp"; die "SOFA download failed — fetch $SOFA_URL manually to $SOFA_TARGET"; }
  sudo install -D -m 0644 "$tmp" "$SOFA_TARGET"
  rm -f "$tmp"
fi
# Sanity (warn-only): SOFA files are netCDF — classic netCDF starts "CDF",
# netCDF-4 is an HDF5 container starting \x89HDF.
if [ ! -s "$SOFA_TARGET" ]; then
  warn "SOFA file is empty — download failed?"
else
  magic=$(head -c 4 "$SOFA_TARGET" | od -An -tx1 | tr -d ' \n')
  case "$magic" in
    434446*|89484446) : ;;  # "CDF…" / "\x89HDF"
    *) warn "SOFA file magic '$magic' doesn't look like netCDF/HDF5 — proceeding anyway" ;;
  esac
fi

# ── HeSuVi source WAV: local attic or manual ─────────────────────────────────
HESUVI_WAV="/etc/pipewire/hrtf/hesuvi/oal+++.wav"
# The ONLY allowed backup/ reference left in rehydrate: a gitignored local
# attic that exists on machines that ran the old sync. Not in the tracked tree.
HESUVI_ATTIC="$REPO_ROOT/backup/etc/pipewire/hrtf/hesuvi/oal+++.wav"
if [ ! -s "$HESUVI_WAV" ]; then
  if [ -s "$HESUVI_ATTIC" ]; then
    echo "  installing oal+++.wav from local attic"
    sudo install -D -m 0644 -o root -g root "$HESUVI_ATTIC" "$HESUVI_WAV"
  else
    die "oal+++.wav not found (not redistributed in this repo — HeSuVi licensing). \
Download a HeSuVi release (https://sourceforge.net/projects/hesuvi/), take hrir/oal+++.wav \
(14-channel HRIR), place it at $HESUVI_WAV (or $HESUVI_ATTIC) and re-run this section."
  fi
fi

# ── Derive the 14 mono IRs the convolver actually loads (idempotent) ─────────
# Guard on the count, not the first file — a run that died mid-loop must
# re-derive (ffmpeg -y makes the loop overwrite-safe).
if [ "$(ls /etc/pipewire/hrtf/hesuvi/ir_*.wav 2>/dev/null | wc -l)" -ne 14 ]; then
  echo "  splitting oal+++.wav into 14 mono IRs (per HeSuVi channel layout)"
  ensure_pkg ffmpeg
  declare -a names=(fl_l fl_r sl_l sl_r rl_l rl_r fc_l fc_r fr_l fr_r sr_l sr_r rr_l rr_r)
  for i in "${!names[@]}"; do
    sudo ffmpeg -hide_banner -loglevel error -y \
      -i "$HESUVI_WAV" \
      -af "pan=mono|c0=c$i" -ar 48000 \
      "/etc/pipewire/hrtf/hesuvi/ir_${names[$i]}.wav"
  done
fi

# ── Filter-chain configs (tracked payload) ───────────────────────────────────
install_file 0644 root:root etc/pipewire/pipewire.conf.d/90-hrtf-surround.conf   /etc/pipewire/pipewire.conf.d/90-hrtf-surround.conf
install_file 0644 root:root etc/pipewire/pipewire.conf.d/91-hesuvi-surround.conf /etc/pipewire/pipewire.conf.d/91-hesuvi-surround.conf

# Ensure pipewire runs for $NODE_USER (linger so user services survive logouts)
sudo loginctl enable-linger "$NODE_USER"
# `env` carries the var explicitly — sudo's env_reset rejects bare VAR=x
# assignments on the command line without a SETENV tag.
sudo -u "$NODE_USER" env XDG_RUNTIME_DIR="/run/user/$(id -u "$NODE_USER")" \
  systemctl --user restart pipewire pipewire-pulse wireplumber 2>/dev/null \
  || warn "couldn't restart user PipeWire (no user session?). Will pick up on next login."

ok "audio chain installed"
