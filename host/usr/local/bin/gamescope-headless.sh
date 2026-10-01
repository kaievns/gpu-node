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
[ -r /etc/gamescope-headless/resolution ] && . /etc/gamescope-headless/resolution
exec gamescope --backend drm --prefer-output HDMI-A-1 -W "${GS_W:-1280}" -H "${GS_H:-800}" -r "${GS_R:-90}" --hdr-enabled -e -- steam -gamepadui > "$LOG" 2>&1
