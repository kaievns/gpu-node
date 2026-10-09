#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

python3 "$REPO_ROOT/scripts/gen-edid.py" --check >/dev/null \
  && ok "gameland.bin matches its generator" || fail "gameland.bin is stale (rerun scripts/gen-edid.py)"
cmp -s "$PAYLOAD_DIR/usr/lib/firmware/edid/gameland.bin" /usr/lib/firmware/edid/gameland.bin \
  && ok "gameland EDID installed" || fail "/usr/lib/firmware/edid/gameland.bin missing or differs from the payload"

grep -q 'drm.edid_firmware=HDMI-A-1:edid/gameland.bin' /proc/cmdline \
  && ok "EDID injection in /proc/cmdline" \
  || fail "drm.edid_firmware=HDMI-A-1:edid/gameland.bin NOT in cmdline (reboot pending?)"

for m in 1280x800 1920x1200; do
  grep -qx "$m" /sys/class/drm/card*-HDMI-A-1/modes \
    && ok "HDMI-A-1 offers $m" || fail "HDMI-A-1 does not offer $m"
done

grep -q 'nvidia_drm.modeset=1' /proc/cmdline \
  && ok "nvidia_drm.modeset=1 in cmdline" \
  || fail "nvidia_drm.modeset missing"

grep -q 'video=HDMI-A-1:e' /proc/cmdline \
  && ok "video=HDMI-A-1:e (force-enable connector) in cmdline" \
  || fail "video=HDMI-A-1:e missing"
