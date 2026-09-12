#!/usr/bin/env bash
# host/20-boot — systemd-boot entry + EDID firmware + initramfs rebuild.
# Reboot required after this section.
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

# Inject the real Steam Deck EDID firmware (256B HDR10).
install_file 0644 root:root usr/lib/firmware/edid/steamdeck.bin /usr/lib/firmware/edid/steamdeck.bin

# ╔══════════════════════════════════════════════════════════════════════╗
# ║ MACHINE-SPECIFIC UUIDs AHEAD.                                        ║
# ║ host/boot/loader/entries/arch.conf hardcodes root=UUID=… and         ║
# ║ resume=UUID=… for the ORIGINAL NVMe's partitions. A reinstalled disk ║
# ║ gets NEW UUIDs — installing the payload arch.conf unmodified on such ║
# ║ a system produces an UNBOOTABLE machine. Update the UUIDs in         ║
# ║ /boot/loader/entries/arch.conf (blkid /dev/nvme0n1p3 for root,       ║
# ║ p2 for resume/swap) before rebooting. The check below is warn-only.  ║
# ╚══════════════════════════════════════════════════════════════════════╝

# systemd-boot loader.conf + arch.conf (cmdline includes drm.edid_firmware,
# nvidia_drm.modeset, video=HDMI-A-1:e).
install_file 0644 root:root boot/loader/loader.conf       /boot/loader/loader.conf
install_file 0644 root:root boot/loader/entries/arch.conf /boot/loader/entries/arch.conf

# Warn-only UUID sanity check against the running system.
if command -v findmnt >/dev/null 2>&1; then
  payload_root_uuid=$(sed -n 's/.*root=UUID=\([0-9a-fA-F-]*\).*/\1/p' \
    "$PAYLOAD_DIR/boot/loader/entries/arch.conf")
  live_root_uuid=$(findmnt -no UUID / 2>/dev/null || true)
  if [ -n "$live_root_uuid" ] && [ -n "$payload_root_uuid" ] \
     && [ "$payload_root_uuid" != "$live_root_uuid" ]; then
    warn "arch.conf root UUID ($payload_root_uuid) != running root UUID ($live_root_uuid)"
    warn "  → edit /boot/loader/entries/arch.conf (root= AND resume=) BEFORE rebooting, or the box won't boot"
  fi
else
  warn "findmnt not available — could not sanity-check arch.conf UUIDs against the running system"
fi

echo "  regenerating initramfs (nvidia-modeset loads post-rootfs, but mkinitcpio -P is safe)"
sudo mkinitcpio -P

warn "REBOOT REQUIRED for new cmdline to take effect"
ok "boot config installed"
