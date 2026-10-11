#!/bin/bash
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export GBM_BACKEND=nvidia-drm
export WLR_NO_HARDWARE_CURSORS=1
export PULSE_SINK=Surround_HRTF
export STEAM_GAMESCOPE_HDR_SUPPORTED=1
export DXVK_HDR=1
export PROTON_ENABLE_HDR=1
export __GL_SHADER_DISK_CACHE=1
export __GL_SHADER_DISK_CACHE_PATH=$HOME/.cache/nvidia
export __GL_SHADER_DISK_CACHE_SIZE=12000000000
export __GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1
export VKD3D_SHADER_CACHE_PATH=$HOME/.cache/vkd3d-proton
export DXVK_STATE_CACHE_PATH=$HOME/.cache/dxvk
LOG="${XDG_STATE_HOME:-$HOME/.local/state}/gamescope-headless.log"
mkdir -p "$(dirname "$LOG")"
# Mode follows the Moonlight client (stream-mode) unless stream-res pins one.
export GAMESCOPE_MODE_SAVE_FILE="$HOME/.config/gamescope/modes.cfg"
MODE=()
if [ -r /etc/gamescope-headless/resolution ]; then
  . /etc/gamescope-headless/resolution
  MODE=(-W "$GS_W" -H "$GS_H" -r "$GS_R")
fi
# HDR stays available; stream-hdr picks SDR or HDR (SDR by default).
/usr/local/bin/stream-hdr --boot
exec gamescope --backend drm --prefer-output HDMI-A-1 "${MODE[@]}" --hdr-enabled -e -- steam -gamepadui > "$LOG" 2>&1
