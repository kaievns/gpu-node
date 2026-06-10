#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

[ -f /usr/lib/firmware/edid/steamdeck.bin ] \
  && [ "$(stat -c%s /usr/lib/firmware/edid/steamdeck.bin)" -eq 256 ] \
  && ok "Steam Deck EDID firmware present (256 B)" \
  || fail "EDID firmware missing or wrong size"

grep -q 'drm.edid_firmware=HDMI-A-2:edid/steamdeck.bin' /proc/cmdline \
  && ok "EDID injection in /proc/cmdline" \
  || fail "drm.edid_firmware NOT in cmdline (reboot pending?)"

grep -q 'nvidia_drm.modeset=1' /proc/cmdline \
  && ok "nvidia_drm.modeset=1 in cmdline" \
  || fail "nvidia_drm.modeset missing"

grep -q 'video=HDMI-A-2:e' /proc/cmdline \
  && ok "video=HDMI-A-2:e (force-enable connector) in cmdline" \
  || fail "video=HDMI-A-2:e missing"
