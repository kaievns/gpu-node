# gpu-node-controller — k8s cluster-side lifecycle controller for gpu-node

A tiny bash + kubectl + python3 control loop that lives **on the cluster** (not
on gpu-node) and enforces **mutually-exclusive gaming/compute modes** on the
gpu-node host. Pairs with the host-side `gaming-agent` HTTP service captured at
[`host/opt/gaming-agent/`](../../host/opt/gaming-agent/).

## What it does

```
                       WOL from Moonlight              client connects
   SLEEPING ────────────────────────────────► GAMING_IDLE ─────────────► GAMING_ACTIVE
      ▲                                            ▲                          │
      │ idle-check.timer (15 min idle)             │ flip back after          │ disconnect watchdog → kill-running-game.sh
      │                                            │ COOLDOWN (5 min)         │
      │                                            │                          ▼
      │                                            │                     GAMING_IDLE
      │                                            │
      │  controller sees pending GPU pod ──┐       │
      │  WOL if needed + flip via agent    │       │
      │                                    ▼       │
      └──────────────────────────  COMPUTE (k8s pod runs nvidia-smi etc.)
```

Mutual exclusion is enforced by a **dynamic `mode=gaming:NoSchedule` taint**
on `gpu-node`, applied/removed by this controller. Compute workloads must
tolerate the two static taints (`gpu=true` + `dynamic-node=true`) but **must
not** tolerate `mode=gaming` — that's how they're naturally blocked while the
box is in gaming mode.

On the host side, a flip runs `gpu-profile` (v4.0): both modes run the card's max PL with
the core boost ceiling lifted; **compute** additionally sets
`EXCLUSIVE_PROCESS` as defense in depth against accidental co-tenant CUDA
contexts (the taint is the primary gate), while **gaming** runs `DEFAULT`.
The agent enforces ordering — the gaming stack is stopped *before* the switch
to `EXCLUSIVE_PROCESS`, since flipping under a live Sunshine stream kills
NVENC.

## Components

| File | What |
|---|---|
| `01-namespace.yaml` | `gpu-node-system` namespace |
| `02-rbac.yaml` | ServiceAccount + ClusterRole (nodes get/list/watch/patch + pods get/list/watch) + binding |
| `03-secret.yaml.example` | Template only. The real Secret holds the bearer token shared with the host-side agent — **create via `kubectl create secret` from the host's `/etc/gaming-agent/token`, never commit a populated copy** |
| `04-configmap.yaml` | `controller.sh` (the loop) |
| `05-deployment.yaml` | 1 replica, `hostNetwork: true` (for WOL broadcast), affinity = NOT on gpu-node, image `alpine:3.20` + apk install bash/curl/jq/python3 + download kubectl |

## Configuration knobs (env on the Deployment)

| Var | Default | Meaning |
|---|---|---|
| `NODE` | `gpu-node` | k8s node name to manage |
| `NODE_MAC` | `58:11:22:b0:a6:af` | MAC for WOL magic packet (Intel I225-V on `enp7s0`) |
| `AGENT_URL` | `http://172.16.1.220:8080` | host-side gaming-agent endpoint |
| `COOLDOWN_SECONDS` | `300` | wait this long after the last compute pod terminates before flipping back to gaming. 5 min tolerates brief gaps between queued jobs; raise it if you find yourself running long batch pipelines with multi-minute setup gaps between Jobs |
| `POLL_INTERVAL` | `15` | seconds between loop iterations |
| `WOL_READY_TIMEOUT` | `120` | seconds to wait for `kubectl get node` to show Ready after WOL |

## Install / re-install

```bash
# Prerequisites:
#   - gpu-node joined to the cluster with its static taints (see docs/setup.md)
#   - device plugin running (../device-plugin/nvidia-device-plugin.yaml)
#   - host-side gaming-agent listening on :8080 (../../host/opt/gaming-agent/)

# Generate the shared token on the host (if not already):
ssh kai@172.16.1.220 'sudo cat /etc/gaming-agent/token' > /tmp/token

# Apply the cluster pieces:
kubectl apply -f 01-namespace.yaml
kubectl apply -f 02-rbac.yaml
kubectl -n gpu-node-system create secret generic gpu-node-controller-secret \
    --from-literal=agent-token="$(cat /tmp/token)"
kubectl apply -f 04-configmap.yaml
kubectl apply -f 05-deployment.yaml
rm /tmp/token
```

## Failure mode

If `/mode/compute` or `/mode/gaming` returns non-2xx, **the controller logs
the error and stays in the current taint state** — pending compute pods stay
Pending (or running ones keep running). It does NOT loop the flip. Investigate
via:

```bash
kubectl -n gpu-node-system logs deployment/gpu-node-controller
ssh kai@172.16.1.220 journalctl -u gaming-agent -n 50
```

To unstick manually:

```bash
# Force-remove the gaming taint (allow compute pods to land)
kubectl taint nodes gpu-node mode-

# Force-add the gaming taint
kubectl taint nodes gpu-node mode=gaming:NoSchedule --overwrite

# Call agent directly
TOKEN=$(ssh kai@172.16.1.220 'sudo cat /etc/gaming-agent/token')
curl -H "Authorization: Bearer $TOKEN" http://172.16.1.220:8080/status
curl -X POST -H "Authorization: Bearer $TOKEN" http://172.16.1.220:8080/mode/compute
curl -X POST -H "Authorization: Bearer $TOKEN" http://172.16.1.220:8080/mode/gaming
```

## What's NOT here

- **Auto-WOL for compute on a schedule**: the controller only WOLs when it
  sees a Pending pod. If you want to wake gpu-node from a cron / CI / curl
  without a pod, just send the WOL magic packet directly to
  `58:11:22:b0:a6:af` from anywhere on the LAN.
- **Monitoring / metrics**: the cluster monitoring stack lives in
  [`../monitoring/`](../monitoring/); this controller doesn't expose metrics
  yet — its observable surface is its logs.
- **Multi-node support**: hardcoded to one node (gpu-node) by design.
