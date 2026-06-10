# rehydrate/

End-to-end rebuild of `gpu-node` (Gameland) from a fresh Arch base install.
All host configs install from the tracked payload tree at [`../host/`](../host/)
(filesystem-mirror layout: `etc/`, `boot/`, `usr/`, `opt/`, `home/kai/`, plus
package lists in `host/meta/`). There is **no sync prerequisite** — clone the
repo and run. To check whether the live box has drifted *ahead* of the repo,
run [`../scripts/sync-from-host.sh`](../scripts/sync-from-host.sh) on the box
and inspect the diff.

## Prereqs (manual — not scripted)

the manual bootstrap in [`../docs/setup.md`](../docs/setup.md) (§§0–4):

- Arch Linux base installed on `/dev/nvme0n1` (1G ESP / 32G swap / 150G `/` / rest `/home`)
- Hostname `Gameland`, the node user (default `kai` — see `NODE_USER` below),
  NOPASSWD sudo, SSH key
- Static IP `172.16.1.220/24`, gateway/DNS `172.16.1.254`
- BIOS: ErP Disabled, Power On By PCIE Enabled, Above 4G Decoding, ReBAR, CSM off
- A k3s control-plane node-token + the cluster kubeconfig on your kubectl machine
- `oal+++.wav` (HeSuVi HRIR) on hand for `host/70` — not redistributed in this
  repo (licensing); the install script tells you exactly where to put it

## Run

```bash
# 1. On gpu-node (with the repo copied locally — git clone or scp):
cd rehydrate
./rehydrate.sh host install         # runs all host/NN/install.sh in order
./rehydrate.sh host verify          # runs all host/NN/verify.sh

# 2. From a machine with kubectl + the cluster's kubeconfig:
./rehydrate.sh cluster install
./rehydrate.sh cluster verify
```

Or single-step `./rehydrate.sh host` (install then verify) and `./rehydrate.sh cluster`.

### Inputs (env vars, prompted if unset)

| Var | Used by | What |
|---|---|---|
| `NODE_USER` | host/70, host/80 | The login user that runs PipeWire/Sunshine. Defaults to `kai`. The payload tree literally mirrors `home/kai/`; only the install *target* is parameterized. |
| `K3S_URL` | host/90 | Cluster API endpoint, e.g. `https://172.16.1.1:6443` |
| `K3S_TOKEN` | host/90 | Node-token from a control-plane node (`cat /var/lib/rancher/k3s/server/node-token`). Never written to disk by these scripts. |
| `AGENT_TOKEN` | cluster/30 | Shared bearer token between controller and host agent. Normally you don't set this — see the token flow below. |

### The agent-token flow

`host/85` generates a fresh token into `/etc/gaming-agent/token` (mode 640,
root:gaming-agent) and drops a transient copy at `/tmp/.gpu-node-agent-token`
(born 0600). `cluster/30` resolves the token in this order: `$AGENT_TOKEN` env
→ the `/tmp` file (same-machine runs) → `ssh kai@172.16.1.220 'sudo cat
/etc/gaming-agent/token'` → interactive prompt. It writes the k8s Secret, then
deletes the `/tmp` copy. The token never lands in the repo.

## Sections

| Order | Section | What | Restartable? |
|---|---|---|---|
| host/10 | packages          | pacman lists from `host/meta/` + yay bootstrap + AUR | yes |
| host/20 | boot              | systemd-boot entry + EDID firmware + mkinitcpio. **Hardcodes the original disk's UUIDs — warns if they don't match the running system; fix before reboot** | reboot req'd |
| host/30 | network           | nftables QoS (DSCP AF41) + WOL ethtool persistence | yes |
| host/40 | nvidia            | nvidia-container-toolkit wiring + nvidia-persistenced + CDI | yes |
| host/50 | cooling           | CoolerControl + watercurve config                  | yes |
| host/60 | gpu-profile       | `gpu-profile` v3.0 + ordering services + 1Hz telemetry | yes |
| host/70 | audio             | PipeWire HRTF: SOFA fetch + HeSuVi IR derivation + filter-chains | yes |
| host/80 | gaming-stack      | gamescope-headless + Sunshine + disconnect watchdog| yes |
| host/85 | gaming-agent      | host FastAPI :8080 + idle-check timer + token gen  | yes |
| host/90 | k3s-agent         | k3s agent join + registries.yaml + node config     | needs `K3S_TOKEN` |
| cluster/10 | ns-rbac        | gpu-node-system namespace + ServiceAccount         | yes |
| cluster/20 | device-plugin  | nvidia/k8s-device-plugin DaemonSet                 | yes |
| cluster/30 | controller     | gpu-node-controller Deployment + Secret with agent token | needs host token |
| cluster/40 | monitoring     | DCGM-exporter (custom-counters ConfigMap **before** daemonset) + Grafana dashboard ConfigMap | yes |
| cluster/50 | alerts         | 5 Grafana alert rules + notification policy fix (via `cluster/monitoring/alerting/apply.py`) | yes |

Manifests live in [`../cluster/`](../cluster/): `controller/`,
`device-plugin/`, `monitoring/` (dcgm-exporter, dashboards, alerting).

## Design notes

- **`install.sh`** is idempotent *by intent*. Re-running should re-apply state
  without breaking anything healthy. Failed sections can be re-run after
  fixing upstream causes. Honest caveat: "idempotent" here means "safe to
  re-run", not "no-op when converged" — some sections restart services on
  every run.
- **`verify.sh`** is read-only — confirms one or more invariants per section.
  Exit code 0 if all pass, non-zero if any fail. Verify is the gate: an
  install that "completed" but doesn't verify is not done. Some checks are
  deliberately warn-only (boot-order timing, WOL BIOS-side state, UUID
  mismatch) — read the yellow lines.
- The order of host sections matters; sections in `cluster/` are mostly
  independent except `30-controller` (wants the token from `host/85`).
- Binary payloads not in git: the MIT-KEMAR `.sofa` is fetched from the
  libmysofa repo at install time; the HeSuVi `oal+++.wav` must be supplied
  locally (`host/70` dies with instructions if missing) and the 14 `ir_*.wav`
  are derived from it with ffmpeg.
- Secrets are never in the tracked tree: the agent token is generated at
  install time, `sunshine_state.json` (pairing/creds) is deliberately never
  captured — re-pair the Deck at `https://172.16.1.220:47990` after a rebuild.
