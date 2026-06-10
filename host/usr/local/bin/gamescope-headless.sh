#!/bin/bash
export XDG_RUNTIME_DIR=/run/user/1000
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export GBM_BACKEND=nvidia-drm
export WLR_NO_HARDWARE_CURSORS=1
export PULSE_SINK=Surround_HRTF
export STEAM_GAMESCOPE_HDR_SUPPORTED=1
export DXVK_HDR=1
export PROTON_ENABLE_HDR=1
export __GL_SHADER_DISK_CACHE=1
export __GL_SHADER_DISK_CACHE_PATH=/home/kai/.cache/nvidia
export __GL_SHADER_DISK_CACHE_SIZE=12000000000
export __GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1
export VKD3D_SHADER_CACHE_PATH=/home/kai/.cache/vkd3d-proton
export DXVK_STATE_CACHE_PATH=/home/kai/.cache/dxvk
exec gamescope --backend drm --prefer-output HDMI-A-2 -W 1280 -H 800 -r 90 --hdr-enabled -e -- steam -gamepadui > /tmp/gamescope-headless.log 2>&1
