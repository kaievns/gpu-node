# Setup — bare metal to running node

This is the manual bootstrap that [rehydrate](../rehydrate/README.md) does
*not* cover: BIOS, the Arch base install, the user/SSH posture, and the
secrets you have to bring yourself. Once the box boots Arch with SSH and a
static IP, everything else is scripted — hand off to `rehydrate.sh` and stop
typing.

All values below are this box's real values (see the fork-notes table in the
top-level [README](../README.md) if you're adapting this for your own
hardware):

| Thing | Value |
|---|---|
| Hostname | `Gameland` (k8s node name is `gpu-node`, forced via k3s config — not the hostname) |
| Static IP | `172.16.1.220/24` |
| Gateway / DNS | `172.16.1.254` (OpenWrt), DNS also `1.1.1.1` |
| NIC | `enp7s0` (Intel I225-V), MAC `58:11:22:b0:a6:af` (the WOL target) |
| Disk | single 1 TB NVMe (Crucial P5 Plus), `/dev/nvme0n1` |
| k3s API | `https://172.16.1.1:6443` (3-server HA: .1/.2/.3) |
| GPU | RTX 3080 10 GB, driver `nvidia-open` |

## 0. Before you start

- Your SSH public key, on your clipboard.
- Arch ISO on USB (`dd` mode).
- The k3s join token from a control-plane node:
  `sudo cat /var/lib/rancher/k3s/server/node-token`
- A machine with `kubectl` + the cluster kubeconfig (the cluster half of
  rehydrate runs from there, not from the box).

## 1. BIOS (ASUS ROG Strix B550-I Gaming)

Del at POST, F7 for Advanced Mode. The first two are load-bearing — without
them WOL-from-powered-off does not work, and the whole wake-for-work design
dies:

| Setting | Value | Why |
|---|---|---|
| Advanced → APM → **ErP Ready** | **Disabled** | ErP cuts +5VSB in S4/S5, which kills WOL from a sleeping/off node |
| Advanced → APM → **Power On By PCIE** | **Enabled** | arms the I225-V NIC for the magic packet |
| Advanced → APM → Restore AC Power Loss | Power On | headless box self-recovers after an outage |
| Advanced → PCI → Above 4G Decoding + Re-Size BAR | Enabled | small GPU win; needs CSM off |
| Boot → CSM | Disabled | pure UEFI for systemd-boot + ReBAR |
| Boot → Fast Boot | Disabled | |
| Boot → Secure Boot → OS Type | Other OS | boots unsigned Arch, no shim |
| Advanced → CPU → SVM Mode | Enabled | virtualization |
| Ai Tweaker → **D.O.C.P.** | your kit's profile | AMD's XMP — runs the DDR4 at rated speed |

**Q-Fan (Monitor → Q-Fan Configuration)** — these are only the
pre-CoolerControl fallback, but get them right anyway:

- `CPU_FAN` / `CHA_FAN` (the two radiator fans): **PWM mode**, flat ~40%
  manual curve, **no fan-stop** — software owns the real water-temp curve
  from the cooling stage onward.
- `AIO_PUMP` (Alphacool DC-LT): **PWM, then Full Speed**. The pump must
  never be throttled by a BIOS curve. It stays at 100% forever, in BIOS and
  in CoolerControl.

## 2. Arch base install

Boot the ISO. This is the only part that needs a monitor and keyboard on the
box.

### Partition `/dev/nvme0n1` (single disk — there is no second NVMe)

| # | Size | Type | FS | Mount |
|---|---|---|---|---|
| p1 | 1G | `ef00` | FAT32 | `/boot` (ESP) |
| p2 | 32G | `8200` | swap | hibernate target (= RAM size) |
| p3 | 150G | `8300` | ext4 | `/` |
| p4 | rest (~748G) | `8300` | ext4 | `/home` (game installs) |

```bash
DISK=/dev/nvme0n1
sgdisk --zap-all "$DISK" && wipefs -a "$DISK"
# create the table with gdisk, then:
mkfs.fat -F32 "${DISK}p1"; mkswap "${DISK}p2"
mkfs.ext4 "${DISK}p3";     mkfs.ext4 "${DISK}p4"
mount "${DISK}p3" /mnt
mount --mkdir "${DISK}p1" /mnt/boot
mount --mkdir "${DISK}p4" /mnt/home
swapon "${DISK}p2"
```

### Bootstrap

```bash
pacstrap -K /mnt base linux linux-firmware amd-ucode \
    networkmanager openssh sudo vim git base-devel efibootmgr ethtool
genfstab -U /mnt >> /mnt/etc/fstab
arch-chroot /mnt
```

Inside the chroot: timezone, locale, and hostname:

```bash
ln -sf /usr/share/zoneinfo/Australia/Sydney /etc/localtime && hwclock --systohc
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "Gameland" > /etc/hostname
```

The Kubernetes node name `gpu-node` does *not* come from the hostname — it's
forced by `node-name:` in [`host/etc/rancher/k3s/config.yaml`](../host/etc/rancher/k3s/config.yaml),
installed later by rehydrate. The hostname can stay pretty.

> **Driver note:** don't install the legacy `nvidia` package — it no longer
> exists for this card on Arch. This box runs **`nvidia-open`** (595 series).
> You don't need to install it now; rehydrate `host/10-packages` installs the
> full captured package set including `nvidia-open`.

### Initramfs — systemd hooks, and NO `resume` hook

`/etc/mkinitcpio.conf` uses the **systemd**-based hook set, e.g.:

```
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block filesystems fsck)
```

Explicitly: **do not add the `resume` hook.** With the systemd initramfs,
hibernate resume is driven entirely by the `resume=UUID=...` kernel cmdline
(§6) — the legacy `resume` hook is for the old `base`/`udev` initramfs and is
not needed here. (The original build plan got this wrong.)

```bash
mkinitcpio -P
```

### Bootloader — systemd-boot

```bash
bootctl install
```

`loader.conf` and the boot entry are tracked in the repo
([`host/boot/loader/`](../host/boot/loader/)) and installed by rehydrate
`host/20-boot` — but for the *first* boot you need a minimal working entry
now. Grab your UUIDs:

```bash
blkid -s UUID -o value /dev/nvme0n1p3   # ROOT
blkid -s UUID -o value /dev/nvme0n1p2   # SWAP (resume)
```

and write `/boot/loader/entries/arch.conf` with at least
`root=UUID=<root> rw resume=UUID=<swap>`. The full cmdline (EDID injection,
nvidia KMS, etc.) lands when rehydrate installs the repo copy — **but the
repo copy carries the *old* machine's UUIDs**, so see §6 before you reboot
after `host/20-boot`.

Enable services, exit, reboot:

```bash
systemctl enable NetworkManager sshd
exit && umount -R /mnt && swapoff -a && reboot
```

### Static IP + WOL persistence (NetworkManager)

The box uses NetworkManager (this is what the original build used and what
the live host runs — not systemd-networkd). From the console or a first DHCP
SSH session:

```bash
sudo nmcli con add type ethernet con-name homelab ifname enp7s0 \
    ipv4.addresses 172.16.1.220/24 \
    ipv4.gateway   172.16.1.254 \
    ipv4.dns       "172.16.1.254 1.1.1.1" \
    ipv4.method    manual
sudo nmcli con modify homelab 802-3-ethernet.wake-on-lan magic
sudo nmcli con up homelab
```

Verify WOL is armed: `sudo ethtool enp7s0 | grep Wake-on` → want `Wake-on: g`.
(Rehydrate `host/30-network` re-asserts this with ethtool, but the BIOS
settings from §1 are what actually make cold-WOL work.)

NetworkManager connection profiles are deliberately **not** tracked in
`host/` (they can contain Wi-Fi PSKs) — this nmcli step is always manual.

## 3. User `kai` — SSH-key-only, root locked

```bash
useradd -m -G wheel -s /bin/bash kai
install -d -m 700 -o kai -g kai /home/kai/.ssh
echo "ssh-ed25519 AAAA... you@laptop" > /home/kai/.ssh/authorized_keys
chmod 600 /home/kai/.ssh/authorized_keys && chown kai:kai /home/kai/.ssh/authorized_keys

echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

passwd -l root        # root locked
passwd -d kai         # kai has NO password — key-only + NOPASSWD sudo
```

sshd: keys only, no root login (`/etc/ssh/sshd_config.d/10-gpu-node.conf`
with `PermitRootLogin no`, `PasswordAuthentication no`,
`AuthenticationMethods publickey`). Keep password auth on for the very first
boot if you're nervous about the key paste; turn it off once key login is
verified — and verify from a *second* session before closing the first.

> **No-console-recovery caveat:** with root locked and kai passwordless,
> there is no way to log in at the physical console. If you ever lose SSH
> access (bad sshd config, deleted key), recovery is the Arch ISO +
> `arch-chroot` — fix `authorized_keys` or sshd config from there. Accepted
> trade-off; know it before you need it.

## 4. Secrets you must bring

Nothing secret is in this repo (by design). Three things exist only outside
it:

1. **k3s join token** — feed it to rehydrate stage `host/90-k3s-agent` via
   env (it prompts otherwise):
   ```bash
   K3S_URL=https://172.16.1.1:6443 K3S_TOKEN=<node-token> ./rehydrate.sh host
   ```
   The token is never written to the repo or to disk outside k3s's own state.
2. **gaming-agent bearer token** — you do *not* bring this one; stage
   `host/85-gaming-agent` generates a fresh `openssl rand -hex 32` at
   `/etc/gaming-agent/token` (640 `root:gaming-agent`), or reuses an existing
   one. It's handed to the cluster side via a transient
   `/tmp/.gpu-node-agent-token` (or SSH-fetched, or `AGENT_TOKEN` env) when
   `cluster/30-controller` creates the k8s Secret.
3. **Sunshine credentials + pairing state** — `sunshine_state.json` (web
   creds, paired-client certs) is deliberately never in the repo. After the
   gaming stack is up: open `https://172.16.1.220:47990`, set the web
   username/password on first visit, then re-pair Moonlight clients (the
   Steam Deck) via the PIN flow.

## 5. Hand-off to rehydrate

```bash
# On gpu-node:
git clone <this-repo> ~/gpu-node && cd ~/gpu-node/rehydrate
K3S_URL=https://172.16.1.1:6443 K3S_TOKEN=<token> ./rehydrate.sh host
sudo reboot     # host/20-boot changed the kernel cmdline — see §6 FIRST
./rehydrate.sh host verify

# From your kubectl machine (NOT the box):
git clone <this-repo> && cd gpu-node/rehydrate
./rehydrate.sh cluster            # install + verify
```

Rehydrate installs everything from the tracked [`host/`](../host/) tree —
that tree is the source of truth, kept current from the live box with
[`scripts/sync-from-host.sh`](../scripts/sync-from-host.sh). If you've made
changes on the host since the last sync, sync before you trust a rebuild.

`cluster/30-controller` needs the agent token from `host/85` — run the host
side first, or export `AGENT_TOKEN` yourself.

### Post-checks

```bash
# GPU + mode
nvidia-smi --query-gpu=name,driver_version,power.limit,compute_mode --format=csv
# Gaming stack
systemctl is-active gamescope-headless sunshine gaming-agent coolercontrold
# Cluster (from kubectl machine)
kubectl get node gpu-node                              # Ready
kubectl describe node gpu-node | grep -A3 Taints       # gpu, dynamic-node (+ mode=gaming if idle)
kubectl -n gpu-node-system logs deploy/gpu-node-controller --tail=20
# Cooling
sensors asusec-isa-0000 | grep T_Sensor                # water temp
# WOL: suspend it, then wake it via the controller (see architecture.md —
# a magic packet from another VLAN will NOT arrive)
```

Then visit the Sunshine WebUI (§4.3), pair the Deck, and play. The full
mode-arbitration design lives in [architecture.md](architecture.md).

## 6. Boot-entry gotchas

The live entry is tracked at
[`host/boot/loader/entries/arch.conf`](../host/boot/loader/entries/arch.conf):

```
options root=UUID=cd96...d30 rw resume=UUID=6919...4b9 iommu=pt
        nvidia_drm.modeset=1 acpi_enforce_resources=lax nvidia_drm.fbdev=1
        drm.edid_firmware=HDMI-A-2:edid/steamdeck.bin video=HDMI-A-2:e
```

One line each:

| Param | Why it's there |
|---|---|
| `root=UUID=... rw` | root filesystem (nvme0n1p3) |
| `resume=UUID=...` | swap partition (nvme0n1p2) holding the hibernate image — with the systemd initramfs this cmdline alone enables resume, no mkinitcpio hook |
| `iommu=pt` | IOMMU passthrough mode; effectively a no-op here (no VFIO), harmless leftover from the build |
| `nvidia_drm.modeset=1` | NVIDIA KMS — required for gamescope's DRM backend and Sunshine's KMS capture; without it the whole headless gaming stack is dead |
| `nvidia_drm.fbdev=1` | framebuffer device on top of nvidia-drm, keeps a usable kernel console on this no-Xorg box |
| `drm.edid_firmware=HDMI-A-2:edid/steamdeck.bin` | kernel-injects the vendored, *valid* Steam Deck EDID ([`host/usr/lib/firmware/edid/steamdeck.bin`](../host/usr/lib/firmware/edid/steamdeck.bin)) — nvidia-modeset cannot read dummy-plug EDIDs over DDC and silently ignores *invalid* injected ones; only a valid EDID gets you the 1280x800@90 HDR mode |
| `video=HDMI-A-2:e` | forces that connector enabled regardless of hot-plug detect |
| `acpi_enforce_resources=lax` | lets the `nct6775` driver write fan PWM registers in an I/O region ACPI also claims — required for CoolerControl on this ASUS board (coolercontrold auto-added it on first run; now pinned here) |

Gotchas:

- **The UUIDs are machine-specific.** The repo copy carries the *live box's*
  UUIDs. After any reinstall/repartition, `blkid` the new root and swap
  partitions and update both the live `/boot/loader/entries/arch.conf` *and*
  the repo copy (then `scripts/sync-from-host.sh` keeps them honest).
  Blindly letting rehydrate `host/20-boot` install the repo entry onto a
  freshly-partitioned disk will produce an unbootable entry.
- After changing the EDID file or the entry, rebuild the initramfs
  (`sudo mkinitcpio -P`) — `host/20-boot` does this for you.
- A reboot is required for cmdline changes; rehydrate warns but does not
  reboot for you.
- No dummy plug is needed: `video=HDMI-A-2:e` force-enables the connector
  with nothing attached, and the EDID is kernel-injected (a plug wouldn't
  help anyway — nvidia-modeset can't read dummy-plug EDIDs over DDC).
