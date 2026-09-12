# host/ — gpu-node host configuration payload

This tree is the curated, tracked copy of gpu-node's host configuration, in
filesystem-mirror layout: a file at `host/etc/systemd/system/foo.service`
installs to `/etc/systemd/system/foo.service` on the box. It was promoted
from a gitignored live mirror (the old `backup/` attic) — what's here is the
deliberate subset: everything needed to rebuild the host, nothing vestigial.

The [rehydrate host stages](../rehydrate/host/) install **from this tree**.
If a file matters for disaster recovery, it lives here; if it lives here, a
rehydrate stage installs it.

## Sync and drift workflow

[`scripts/sync-from-host.sh`](../scripts/sync-from-host.sh) pulls the live
host's files **into** this tree. After a sync, `git diff` *is* the drift
report:

- Changed something on the box directly? Sync, review the diff, commit — the
  repo catches up to reality.
- Changed something here first? The diff after sync shows the repo edit being
  "reverted" by the live file — apply the repo version to the host (rerun the
  relevant rehydrate stage, or install by hand), then sync again to confirm
  the diff is clean.

The repo is the record of intent; the host is what's actually running. A
clean diff means they agree.

## Deliberately NOT in this tree

- **Secrets.** `/etc/gaming-agent/token` (the agent bearer token — generation
  recipe in [etc/gaming-agent/token.example](etc/gaming-agent/token.example))
  and `~/.config/sunshine/sunshine_state.json` (Sunshine credentials and
  client pairing). The sync script excludes them; never add them.
- **Audio binaries.** The HRTF `.sofa` files and the HeSuVi `oal+++.wav`
  source are fetched at install time, and the 14 per-channel `ir_*.wav`
  impulse responses are derived from `oal+++.wav` with ffmpeg
  (recipe in [docs/audio.md](../docs/audio.md), executed by
  [rehydrate/host/70-audio](../rehydrate/host/70-audio/)).
- **Exception:** [usr/lib/firmware/edid/steamdeck.bin](usr/lib/firmware/edid/steamdeck.bin)
  *is* vendored — a 256-byte valid Steam Deck EDID from
  [github.com/Bloodhundur/steamdeckedid](https://github.com/Bloodhundur/steamdeckedid).
  It's load-bearing: nvidia-modeset ignores invalid injected EDIDs (and can't
  read dummy-plug EDIDs over DDC), so a known-good binary is the only thing
  that makes the headless HDR pipeline come up.
- **Live-host cruft, on purpose.** These exist on the box but were not
  promoted: the vestigial `gpu-profile.service.d/{10-coolbits,10-no-coolbits}.conf`
  drop-in pair (they cancel out — net effect zero), `gamescope-revert.sh`,
  `gs-safe-ondisk.sh`, and `steamdeck-edid-revert.sh` (broken — they
  reference deleted units and out-of-repo backups), and the nested
  `.service.d/etc/...` duplicate directories (artifacts of an `rsync -R` bug
  in the old sync script).

## Known repo-ahead-of-host divergences

Comment-level and intentional. After a sync these show up as diffs — do
**not** "fix" them back to the host's wording:

- [etc/systemd/system/gpu-profile.service](etc/systemd/system/gpu-profile.service)
  — the live host's `Description=` still says "caps power below the SFF PSU
  transient-reset threshold". Stale since gpu-profile v3.0: the PSU-transient
  hypothesis was a red herring, and both modes now run PL370. The repo copy
  carries the corrected description.
- [opt/gaming-agent/agent.py](opt/gaming-agent/agent.py) — the live host's
  docstrings/comments still claim compute=PL300 / gaming=PL370. Also stale
  since v3.0 (both modes PL370; the modes differ in compute mode and which
  services run). The repo copy carries the corrected comments. The code
  itself is identical — only `gpu-profile` knows the actual numbers.
- [etc/pipewire/pipewire.conf.d/](etc/pipewire/pipewire.conf.d/) — both conf
  headers carried stale priority claims from earlier iterations (HeSuVi
  "200", BinauralBus "system default", Surround_HRTF "100"). The repo copies
  describe the operative values: HeSuVi 3000 = default, BinauralBus 2000 =
  Sunshine's capture bus, Surround_HRTF 50 but pinned via PULSE_SINK.

## Directory map

| Path | What |
|---|---|
| [boot/loader/](boot/loader/) | systemd-boot config. `entries/arch.conf` carries the load-bearing kernel cmdline: `drm.edid_firmware=HDMI-A-1:edid/steamdeck.bin video=HDMI-A-1:e`, `nvidia_drm.modeset=1 fbdev=1`, `resume=` (hibernate swap). |
| [etc/coolercontrol/](etc/coolercontrol/) | CoolerControl daemon config: rad fans (nct6798 fan1/fan2) on the "watercurve" driven by coolant temp (asusec `T_Sensor`); pump (AIO_PUMP) pinned 100%. |
| [etc/gaming-agent/](etc/gaming-agent/) | `token.example` only — recipe for generating the bearer token and its k8s Secret twin. The real token is never tracked. |
| [etc/logrotate.d/](etc/logrotate.d/) | Rotation for the 1 Hz GPU telemetry log. |
| [etc/nftables.d/](etc/nftables.d/) | `sunshine-qos.nft` — DSCP AF41 marking on Sunshine's UDP egress so Wi-Fi APs queue the stream in WMM Video AC. |
| [etc/pipewire/pipewire.conf.d/](etc/pipewire/pipewire.conf.d/) | Filter-chain sinks for streamed surround: `BinauralBus` (default, pure stereo), `Surround_HeSuVi` (HeSuVi IR convolver), `Surround_HRTF`. Full design history in [docs/audio.md](../docs/audio.md). |
| [etc/rancher/k3s/](etc/rancher/k3s/) | `config.yaml` (node name `gpu-node`, labels, the two static taints) and `registries.yaml` (`registry.homelab` mirror). |
| [etc/sudoers.d/](etc/sudoers.d/) | NOPASSWD allowlist for the `gaming-agent` user — exact systemctl/gpu-profile/suspend commands only. |
| [etc/systemd/system/](etc/systemd/system/) | The unit graph: `gamescope-headless` (+ drop-ins for caps, deps, stop timeout), `sunshine` (+ drop-ins enforcing DRM-master ordering — gamescope must grab DRM master before Sunshine's KMS capture attaches), `gaming-agent`, `gpu-profile` / `gpu-gaming` (boot-time profile), `gpu-idle-check.timer`, `gpu-telemetry`, `sunshine-qos`, `sunshine-disconnect-watchdog` (kills the running game on client disconnect). |
| [etc/udev/rules.d/](etc/udev/rules.d/) | `99-uinput.rules` — uinput access for Sunshine's virtual gamepad. |
| [home/kai/.config/sunshine/](home/kai/.config/sunshine/) | `sunshine.conf` (KMS capture, HEVC NVENC, 50 Mbit cap, `csrf_allowed_origins` as a plain comma list — JSON arrays are silently rejected) and `apps.json`. No state/credentials. |
| [meta/](meta/) | pacman package lists (explicit / AUR / all), consumed by [rehydrate/host/10-packages](../rehydrate/host/10-packages/). |
| [opt/gaming-agent/](opt/gaming-agent/) | `agent.py` — the FastAPI control plane on :8080 (`/status`, `/mode/compute`, `/mode/gaming`, `/sleep`; refuses compute flips mid-stream) — and `idle-check.sh` (suspends after 15 min idle in gaming mode). |
| [usr/lib/firmware/edid/](usr/lib/firmware/edid/) | `steamdeck.bin` — the vendored EDID (attribution above). |
| [usr/local/bin/](usr/local/bin/) | `gamescope-headless.sh` — gamescope-DRM launch: HDR env, shader caches, `PULSE_SINK` pin routing game audio into the surround chain. |
| [usr/local/sbin/](usr/local/sbin/) | `gpu-profile` (the compute/gaming profiles, with full version history in comments), `gpu-telemetry.sh` (1 Hz power/temp/clock/throttle-bitmap log for post-Xid forensics), `kill-running-game.sh` (kills the game tree, leaves the stack up). |
