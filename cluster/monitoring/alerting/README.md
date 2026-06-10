# gpu-node Grafana alerts

Five hardware-protection alert rules wired into the existing Grafana
Alerting engine (not the kube-prom-stack Alertmanager — that's
`enabled: false` in helm values, and we're not enabling it).

| UID | Severity | Condition | `for` | What it catches |
|---|---|---|---|---|
| `gpu-pump-rpm-low` | **critical** | nct6798 `fan5 < 2000` RPM | 1 min | Coolant pump death — CPU and GPU share one loop; no flow means both fry within minutes |
| `gpu-coolant-high` | warning | asusec `T_Sensor > 50 °C` | 5 min | Sustained load exceeding radiator capacity, or fans not ramping |
| `gpu-temp-high` | **critical** | `DCGM_FI_DEV_GPU_TEMP > 85 °C` | 2 min | Loop failure at the GPU specifically (water moving but block not cooling) |
| `gpu-thermal-violation` | warning | `max(rate(DCGM_FI_DEV_THERMAL_VIOLATION[10m])) > 0` | 5 min | GPU actively thermal-throttling — on this card, with die temp <70 °C, that means GDDR6X junction heat-soak ([lesson](../../../docs/lessons/xid79-gddr6x-heat-soak.md)) |
| `gpu-xid-error` | **critical** | `max(DCGM_FI_DEV_XID_ERRORS) > 0` | 1 min | Any driver Xid error — the alert **value is the Xid code** (79 = fallen off the bus, this box's historical failure) |

Notes:

- `gpu-thermal-violation` needs the custom DCGM counter set
  ([`../dcgm-exporter/04-custom-counters.yaml`](../dcgm-exporter/04-custom-counters.yaml));
  the metric isn't in the exporter's default CSV. Until that's applied the
  rule just sits at OK on no-data.
- The old `gpu-mem-junction-high` rule (DCGM_FI_DEV_MEMORY_TEMP > 95 °C)
  was **removed**: that metric reads a constant 0 on consumer Ampere, so
  the rule could never fire — false confidence on the exact failure mode
  that actually bit this box. `gpu-thermal-violation` is the working
  replacement.
- DCGM queries are wrapped in `max()` because DCGM series carry the
  namespace/pod labels of whichever pod currently holds the GPU.

All rules route through the **root notification policy** to the existing
`Kai Evans` contact point (email → hi@kaievans.co), which `apply.py` sets.

## noDataState = OK, everywhere

Every rule applies with `noDataState: OK` (the apply.py default;
overridable per-rule in the YAML with `noDataState: Alerting|NoData`). The
box **sleeps by design** — it's awake maybe 30% of a typical week, and
while asleep no metrics flow at all. Anything other than OK would push a
NoData notification through the root policy on every suspend. For the same
reason there is no up/down alert: "asleep" and "down" are indistinguishable
from Prometheus. `execErrState` stays `Error` — a broken query should be
loud.

## Edit / apply workflow

1. Edit [`gpu-node-alerts.yaml`](gpu-node-alerts.yaml) — a compact custom
   format (`query` + `condition: {type, value}`, type is `gt` or `lt`
   only) rather than Grafana's verbose native rule JSON.
2. Run [`apply.py`](apply.py). Idempotent — POST, falling back to PUT for
   rules that already exist. Exits non-zero if any rule fails.

```bash
python3 -m pip install --user pyyaml   # one-time
./apply.py
```

Two transports:

```bash
# Default: kubectl exec into the Grafana pod, curl localhost from inside.
./apply.py

# Direct HTTP — e.g. through a port-forward:
kubectl -n observability port-forward svc/prometheus-stack-grafana 3000:80 &
./apply.py --grafana-url http://localhost:3000
```

No auth token either way: Grafana runs anonymous-Admin (homelab trade-off,
LAN-only — see [../README.md](../README.md)).

### Editing in the UI vs re-applying

`apply.py` sets `X-Disable-Provenance: true`, so the provisioned rules stay
editable in the Grafana UI — handy for live threshold tuning. But the next
`apply.py` run overwrites UI edits. Treat the YAML as the source of truth:
tune in the UI, then port the change back into `gpu-node-alerts.yaml`.

### Sharp edge: the notification policy step

`apply.py` step 3 **replaces the entire notification policy tree** with a
single root route to `--receiver-name`. Any nested routes or mute timings
added in the UI are wiped. Fine while one receiver exists;
read-modify-write is a TODO in the script.

## Why Grafana Alerting and not Alertmanager?

The kube-prom-stack chart bundles an Alertmanager driven by
`PrometheusRule` CRDs, but it's disabled in our helm values and Grafana
Alerting was already configured with an email contact point. Grafana
Alerting reads the same Prometheus datasource, has its own
routing/silencing UI, and avoids running two competing alerting systems
for a five-rule homelab.

To switch later: enable Alertmanager in helm values, convert these rules
to `PrometheusRule` CRs (`for:`/`expr:` map 1:1; the threshold folds into
the PromQL), and decommission the Grafana rules — running both means
duplicate notifications.

## What's deliberately NOT alerted on

- **gpu-node up/down** — sleeps by design, see above. A genuinely stuck
  box (failed to wake for a pending job) shows up as the controller
  logging WOL retries, not as a metric absence worth paging on.
- **Sunshine streaming health** — no native metrics; the realistic path is
  parsing Sunshine's journal via the existing Alloy → Loki pipeline.
  Separate task.
