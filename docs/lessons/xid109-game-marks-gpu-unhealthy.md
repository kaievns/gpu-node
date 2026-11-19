# Xid 109: a game crash that blocked every GPU job

**TL;DR.** GPU jobs sat Pending for 5 days while the node looked healthy. The
node reported `nvidia.com/gpu` capacity 1 but allocatable 0. Device plugin
v0.17.0 treats Xid 109 as a fatal GPU fault. Shadow of the Tomb Raider raises
Xid 109 when its own GPU context times out. The plugin then marks the GPU
unhealthy and keeps it that way until the plugin restarts. The fix is device
plugin v0.17.1 or newer, which ignores Xid 109.

## The symptom

On 2026-11-19 a GPU pod stayed Pending from 04:24 to 04:34 UTC. The controller
log showed this cycle twice:

```
1 pending compute pod(s) detected
flipping to compute
compute mode active; mode=gaming taint removed; pending pods will now schedule
no compute pods on gpu-node for 313s (cooldown 300s reached); flipping back
```

The node was Ready and awake, so the controller skipped Wake-on-LAN. The agent
switched to compute mode and the taint came off. The pod still never scheduled.

## The tell: capacity versus allocatable

```
kubectl get node gpu-node -o jsonpath='{.status.capacity.nvidia\.com/gpu} {.status.allocatable.nvidia\.com/gpu}'
1 0
```

Capacity counts devices the plugin registered. Allocatable counts the healthy
ones. A 1/0 split means the plugin saw the GPU and then marked it unhealthy.
`rehydrate/cluster/20-device-plugin/verify.sh` checks allocatable for this
reason.

## The cause

The kernel log shows the trigger:

```
NVRM: Xid (PCI:0000:08:00): 109, pid=..., name=SOTTR.exe, channel 0x0000001e, errorString CTX SWITCH TIMEOUT
```

The device plugin log shows the result a moment later:

```
XidCriticalError: Xid=109 on Device=GPU-...; marking device as unhealthy.
'nvidia.com/gpu' device marked unhealthy: GPU-...
```

Xid 109 is a context switch timeout. It belongs to the process that owned the
context, here the game. The GPU itself keeps working. v0.17.0 lists Xids 13, 31,
43, 45 and 68 as application errors and skips them. It does not skip Xid 109, so
one game hang removes the GPU from Kubernetes.

The plugin never re-checks an unhealthy device. Allocatable stayed at 0 from
2026-11-14 11:10 UTC until the plugin pod was recreated on 2026-11-19. Xid 109
also hit on 2026-10-20, 2026-11-05 and twice on 2026-11-18.

## The fix

[k8s-device-plugin PR #1171](https://github.com/NVIDIA/k8s-device-plugin/pull/1171)
added Xid 109 to the application-error list in v0.17.1. The DaemonSet now pins
v0.17.4, the newest v0.17 release. v0.17.2 to v0.17.4 add only dependency bumps,
Blackwell product labels and an NVML memory-query fix.

## What still breaks this way

- **Other Xids:** any Xid outside the application-error list still marks the GPU
  unhealthy until the plugin restarts. Deleting the plugin pod restores
  allocatable.
- **Silent controller failure:** the controller flips to compute without
  checking allocatable. A 0 there shows up only as a 5-minute cooldown and a
  flip back.
