# Example GPU workloads for gpu-node

Working manifests you can `kubectl apply -f` to run real GPU jobs on
gpu-node. Each one is wired correctly for the controller's mutual-exclusion
flip, so applying it will:

1. WOL the box if asleep.
2. Cause the controller to flip `gpu-node` from gaming → compute mode (the
   gaming stack temporarily shuts down).
3. Run the workload.
4. After the workload terminates, the controller waits 5 min cooldown for
   any follow-up GPU pods. If none, it flips back to gaming.

**Don't apply these while you're actively streaming** — your stream will
disconnect when the gaming stack stops.

## What every GPU pod for gpu-node MUST have

```yaml
spec:
  runtimeClassName: nvidia       # RuntimeClass from ../../device-plugin/nvidia-device-plugin.yaml
  tolerations:                   # matches the two static taints on gpu-node
    - {key: gpu, operator: Equal, value: "true", effect: NoSchedule}
    - {key: dynamic-node, operator: Equal, value: "true", effect: NoSchedule}
  nodeSelector:
    gpu.model: rtx5080           # paranoia; future-proofs if cluster grows
  containers:
    - resources:
        limits:
          nvidia.com/gpu: 1      # claims a real device through the device plugin
```

## What every GPU pod MUST NOT have

- A toleration for `mode=gaming:NoSchedule`. That's the dynamic taint the
  controller manages — toleration here bypasses the mutual-exclusion design
  and lets your CUDA pod land while the gaming stack is up. Gaming mode runs
  the GPU in `DEFAULT` compute mode, so both contexts run — and both run
  badly (stream stutter, slow training). Don't.

## Files

| File | What it does |
|---|---|
| `training-job.yaml` | PyTorch CNN training (synthetic data). ~2-5 min runtime, ~1.5 GB VRAM. Inline script demonstrates AMP/autocast, GradScaler, throughput logging. Edit it as a starting point for real training. |

## Common extensions

### Add persistent checkpoint storage

```yaml
# In the Job's pod template:
volumeMounts:
  - name: checkpoints
    mountPath: /mnt/checkpoints
volumes:
  - name: checkpoints
    persistentVolumeClaim:
      claimName: training-checkpoints   # define a PVC separately
```

In your training code: `torch.save(model.state_dict(), "/mnt/checkpoints/foo.pt")`.

### Pull large datasets

If you don't already have a cluster-wide PVC pattern, use an `initContainer`
to fetch the dataset once per pod:

```yaml
initContainers:
  - name: fetch-data
    image: curlimages/curl:8.10.1
    command: ["sh", "-c"]
    args:
      - |
        curl -sL "https://your.dataset.url/data.tar.gz" -o /data/data.tar.gz
        cd /data && tar xzf data.tar.gz
    volumeMounts:
      - name: dataset
        mountPath: /data
```

Or mount an NFS share / S3-via-rclone-sidecar.

### Run interactively (Jupyter notebook)

Use a `Deployment` + `Service` instead of a `Job`, with `image:
jupyter/datascience-notebook` and the same tolerations. The controller flips
to compute as long as the pod is Running. **Caution: while you're working
in the notebook, the gaming stack stays down and the idle-sleep timer is
disabled (controller is in compute mode).** When you `kubectl delete` the
Deployment, the 5-min cooldown starts.

### Force back to gaming early (skip the 5-min cooldown)

```bash
# From your laptop:
TOKEN=$(ssh kai@172.16.1.220 'sudo cat /etc/gaming-agent/token')
curl -X POST -H "Authorization: Bearer $TOKEN" http://172.16.1.220:8080/mode/gaming
kubectl taint nodes gpu-node mode=gaming:NoSchedule --overwrite
```

This is what `../test-flip.sh` does at the end of its run.

## Operational notes

- **GPU memory**: 10 GB physical. Mind your batch size. PyTorch's allocator
  pre-grabs memory aggressively; `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True`
  is sometimes helpful.
- **Multi-GPU**: there's only one. `nvidia.com/gpu: 2` will never schedule.
- **MIG / GPU sharing**: not configured. Use time-slicing in the device
  plugin config if you ever want multiple pods to share the GPU
  simultaneously (not currently desired given the mutual-exclusion design).
- **Power / compute mode** (`gpu-profile` v4.0): both modes run the card's max PL with
  the core boost ceiling lifted; compute additionally sets
  `EXCLUSIVE_PROCESS` as defense in depth against stray co-tenant CUDA
  contexts. Note CUDA workloads force P2 pstate, so memory clock sits at
  9251 MHz by VBIOS design — not a misconfiguration.
