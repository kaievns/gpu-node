# Xid 79: the GDDR6X heat-soak postmortem

**TL;DR.** A water-cooled RTX 3080 that gamed flawlessly for hours would fall
off the PCIe bus (Xid 79) after roughly three hours of sustained ML training.
Every software hypothesis — a new Python dependency, PSU transients, PCIe
seating, `EXCLUSIVE_PROCESS`, power limits — was wrong, and some were
expensively wrong. The actual cause was GDDR6X memory-junction heat-soak in a
closed FormD T1, invisible because consumer Ampere does not expose memory
temperature on Linux at all. The fix was a fan and a repad, not code. The
lesson is the diagnostic shape: **a thermal throttle bit firing while every
visible temperature is comfortable means the hot component is the one you
can't see.**

Hardware context: RTX 3080 10GB (GA102, GDDR6X), nvidia-open 595.71.05,
custom single-loop water cooling (CPU + GPU, one radiator, top-mounted),
FormD T1 sandwich-layout SFF case. Workload: transformer training
(~250M params, bf16 + AdamW), runs spanning hours. Full system in
[architecture.md](../architecture.md).

## The symptom

Late May 2026, training runs started dying with:

```
NVRM: Xid (PCI:0000:06:00): 79, pid=..., GPU has fallen off the bus.
```

The GPU vanishes from PCIe entirely; only a reboot brings it back. The
pattern that made it maddening:

- **Sustained compute died at the ~3 hour mark**, repeatably.
- **Gaming never crashed** — hours of streaming at comparable or higher power
  draw, rock solid.
- Every temperature on the dashboard was fine. Water flat at ~39 °C, die in
  the 60s. Nothing in the telemetry looked remotely stressed.

A card that survives heavier *peak* load but dies under lighter *sustained*
load is already whispering "heat-soak". Nobody was listening yet.

## The red-herring gauntlet

In order, with what each cost. Dates are from the
[`gpu-profile` header changelog](../../host/usr/local/sbin/gpu-profile),
which doubled as the lab notebook.

### 1. The new Python dependency (lion-pytorch)

The first crash landed in the first run after adding a new optimizer library.
*Post hoc ergo propter hoc* is a hell of a drug. **Plausible because** new
training deps genuinely do crash GPUs (bad fused kernels exist), and the
timing was perfect. **Cost:** a dependency rollback, wasted re-runs, and a
day of suspicion aimed at an innocent optimizer. The crashes continued
without it.

### 2. The PSU transient theory (2026-05-24, v2.3)

SFF build + Ampere transient spikes + "fell off the bus" reads exactly like a
brownout reset. **Plausible because** that combination is a famous failure
mode, and the box runs a small SFF PSU. The compute power limit was cut
370 W → 320 W to stay "below the transient-reset threshold". **Disproven**
the same day: Xid 79 at step 990/1000 of a normal run, under the lower cap,
water at 39 °C. **Cost:** 50 W of sustained performance, plus a
`gpu-profile.service` Description that kept asserting the theory for weeks
after it died.

### 3. The PCIe reseat

Xid 79 literally means the device disappeared from the bus, so the link
itself was suspect. **Plausible because** a marginal slot contact is the
textbook cause. **Cost:** a full GPU reseat in a sandwich-layout T1 with a
water loop attached — not a casual operation. Nothing was wrong; nothing
changed.

### 4. The EXCLUSIVE_PROCESS suspicion (2026-05-24, v2.4–v2.7)

By elimination: gaming (compute mode `DEFAULT`) never crashed, compute
(`EXCLUSIVE_PROCESS`) did. After stripping the compute profile to factory
defaults still crashed (v2.4), `EXCLUSIVE_PROCESS` was the *last remaining
config difference* between the working and faulting profiles. v2.5 removed
it; three real training runs landed clean; v2.7's changelog wrote
"**Confirmed**: EXCLUSIVE_PROCESS was the Xid 79 trigger."

It was not. A 3-hour overnight run failed with `EXCLUSIVE_PROCESS` long gone.
Three *short* clean runs had "confirmed" a hypothesis about a failure with a
three-hour fuse. **Cost:** a full day of variable bisection, a rework of the
mode-switch agent's detection logic, and a confidently wrong conclusion in
the changelog (corrected in v2.9, 2026-05-27). **Lesson within the lesson:**
your validation runs must be longer than your time-to-failure.

### 5. The power-limit hedges (v2.7–v2.8)

With nothing confirmed, the profile kept PL320 and dropped the `-lgc 0,2160`
boost-ceiling lift "as a hedge". **Plausible because they half-worked:**
fewer watts means slower heat-soak, so the hedges genuinely stretched
time-to-failure — which made them look like partial fixes and muddied every
experiment that followed. The most expensive red herrings are the ones that
almost work. **Cost:** ~3–5 % sustained throughput and a lowered boost
ceiling for two weeks.

## The diagnostic break

During a soak run, `nvidia-smi -q` showed this, with the die at 65–70 °C:

```
Clocks Event Reasons
    SW Thermal Slowdown               : Active      (bitmask 0x20)
```

That is the break. A *thermal* slowdown at 65–70 °C die temperature is
nonsense — the die's slowdown threshold is far higher. The driver was
throttling for a thermal reason it refused to name, which means it was
reacting to a sensor it doesn't report.

On consumer Ampere, NVML exposes die edge and hotspot but **not memory
junction**. There is no field in `nvidia-smi`, and `DCGM_FI_DEV_MEMORY_TEMP`
reads a constant 0 — so the Grafana dashboard was structurally blind to
exactly this. The only major heat source on the card with no Linux-visible
temperature is the GDDR6X. (Windows tools read junction via undocumented
APIs; on Linux you get nothing.)

GDDR6X numbers: junction limit 110 °C, throttle/derate region from ~95 °C,
and 95–105 °C junction under sustained load is normal even on stock coolers.
The hypothesis wrote itself: memory junction crossing ~95 °C fires the SW
slowdown bit; continued soak eventually produces a memory fault the driver
can't survive, and the GPU drops off the bus.

## The physics

Why this card, this case, this workload:

- **The water block cools the die, not the card.** Full-cover block, water
  flat at 39 °C, die in the 60s. But GDDR6X sheds a large fraction of its
  heat through the PCB *backside* into the backplate — which is purely
  passive and needs convective airflow to do anything.
- **The FormD T1 sandwich had zero GPU-compartment convection.** GPU in its
  own closed slot, radiator fans exhausting at the top of the *other*
  compartment. The backplate sat in still air.
- **Compute saturates memory continuously; gaming doesn't.** Training keeps
  the memory controller near 100 % duty for hours (activations, optimizer
  state, gradient traffic every step). Gaming access is bursty — heavy for
  milliseconds, idle between frames — so average memory power is far lower.
  That is the entire gaming-fine/compute-dies asymmetry.
- **Heat-soak is an integral.** Compartment air and backplate temperature
  ratchet up over hours until junction crosses ~95 °C. The driver's slowdown
  sheds some watts but can't create airflow. Eventually: cell fault, bus
  drop, Xid 79. Hence the repeatable ~3-hour fuse, and hence why power-limit
  cuts stretched the fuse without defusing it.

## Validation (2026-05-25)

Side panel off, same training workload: ran well past the three-hour failure
point, no slowdown bit, no crash. Total cost of the decisive experiment:
zero dollars and one evening. It should have been step one — see the
checklist at the end.

## The fixes

| Date | Fix | Result |
|---|---|---|
| 2026-05-25 | Bottom-mounted Noctua intake feeding the GPU compartment; fresh memory thermal pads while the loop was open | Backplate and PCB finally in moving air; failure mode gone |
| 2026-06-08 | PTM7950 phase-change repad on the die | Die-to-coldplate delta 25–45 °C → **10–13 °C** |
| 2026-06-08 | [`gpu-profile` v3.0](../../host/usr/local/sbin/gpu-profile): PL back to 370 W, `-lgc 0,2160` boost lift restored | Full performance recovered; all hedges retired |

Current steady state: sustained 350 W tensor compute holds **60–62 °C edge /
71–72 °C hotspot indefinitely**, fans below max. `EXCLUSIVE_PROCESS` is back
in the compute profile — exonerated, and useful as defense in depth against
accidental co-tenant CUDA contexts.

## Monitoring closure: watching for a temperature you can't read

`DCGM_FI_DEV_MEMORY_TEMP` is **constant 0 on consumer Ampere**. Any panel or
alert built on it is dead weight — it will read "0 °C, all good" while the
memory cooks. The real software-visible signature is:

- `DCGM_FI_DEV_CLOCKS_EVENT_REASONS` with **bit 0x20 (SW Thermal Slowdown)
  set while `DCGM_FI_DEV_GPU_TEMP` is comfortable**, and
- `DCGM_FI_DEV_THERMAL_VIOLATION` accumulating throttle time,
- with `DCGM_FI_DEV_XID_ERRORS` as the after-the-fact tombstone.

These counters are not in dcgm-exporter's default set; they're added in
[`cluster/monitoring/dcgm-exporter/04-custom-counters.yaml`](../../cluster/monitoring/dcgm-exporter/04-custom-counters.yaml)
and surfaced in the Reliability row of the
[gpu-node overview dashboard](../../cluster/monitoring/dashboards/gpu-node-overview.json).
See [`cluster/monitoring/README.md`](../../cluster/monitoring/README.md) for
the stack details.

## Appendix: GDDR6X vs GDDR7 thermals

Context for the next card (distilled from the next-build research; sources:
Tom's Hardware and GamersNexus 5090 reviews, Puget Systems AI benchmarks):

| | GDDR6X (3080, 4090) | GDDR7 (5080, 5090) |
|---|---|---|
| Junction temp limit | 110 °C | 110 °C |
| Junction under sustained load, stock cooler | 95–105 °C | 80–90 °C |
| Voltage swing / power per bit | higher | lower |
| Headroom under sustained compute | tight | ~12 °C better |

GDDR7 is meaningfully cooler per bit but **not a panacea** — a 5090 still
reaches ~96 °C junction in sustained loads. For a sustained-compute box the
margin matters: a used 4090 inherits this exact failure mode; a 5080/5090
reduces (not eliminates) it. Same case, same airflow rules apply.

## How to recognize this failure mode on any card

1. **Crashes only under sustained compute; gaming and bursty loads run for
   hours.** Memory duty cycle is the difference, not peak power.
2. **Time-to-failure is measured in hours and roughly repeatable.** That's
   thermal mass integrating watts — heat-soak, not an electrical transient.
3. **A thermal throttle bit fires while every visible temperature is
   comfortable.** Trust the bit, not the temperatures: the hot component is
   one that isn't instrumented.
4. **The memory temperature metric reads 0 or is absent.** On consumer cards
   that's hidden telemetry, not a cool memory bus. No data ≠ no problem.
5. **Power-limit cuts stretch time-to-failure but don't prevent it.** A real
   electrical problem responds to lower watts; a soak problem just slows
   down.
6. **Run the cheapest decisive experiment first:** side panel off (or a desk
   fan at the backplate), exact same failing workload, past the usual
   failure time. One evening, zero dollars.
7. **If panel-off passes, the fix is mechanical** — airflow over the
   PCB/backplate, repad, active backplate. No driver, dependency, or power
   setting will fix missing convection.

And keep your hypothesis tests longer than your time-to-failure.
