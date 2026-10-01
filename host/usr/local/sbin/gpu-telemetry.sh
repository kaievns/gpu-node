#!/bin/bash
# 1Hz GPU telemetry capture. Output appended to /var/log/gpu-telemetry.log
# via systemd StandardOutput=append in gpu-telemetry.service.
#
# Captures the fields most useful for post-Xid forensics: power, temps,
# util, clocks, pstate, throttle-reason bitmap. The throttle field is
# critical — Xid 79 with a throttle bit set vs no throttle bit set point
# at different root causes.
set -u

echo "=== START $(date -Iseconds) host=$(uname -n) driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null) ==="

while true; do
  ts=$(date -Iseconds)
  # one CSV line; if nvidia-smi hiccups the loop survives + flags it
  data=$(nvidia-smi \
    --query-gpu=timestamp,power.draw,power.limit,temperature.gpu,utilization.gpu,utilization.memory,clocks.gr,clocks.mem,pstate,clocks_event_reasons.active \
    --format=csv,noheader 2>&1) \
    || data="ERROR ($?): $data"
  echo "$ts | $data"
  sleep 1
done
