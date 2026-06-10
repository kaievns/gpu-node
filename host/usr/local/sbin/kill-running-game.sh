#!/bin/bash
# Kill the running Steam game tree on Sunshine client disconnect.
# Leaves Steam, gamescope-headless, and Sunshine running so the next reconnect
# lands back in Big Picture without a stack rebuild.
LOG=/var/log/kill-running-game.log
ts(){ date "+%Y-%m-%d %H:%M:%S"; }
exec >>"$LOG" 2>&1
echo "[$(ts)] === game-kill triggered ==="

# Infrastructure processes we must never touch.
# Note: includes "gamescopereaper" (the gamescope subreaper that hosts Steam),
# but NOT bare "reaper" — Steam's per-app "reaper SteamLaunch" is the launcher
# we DO want to kill.
EXCLUDE='^(steam|steamwebhelper|gamescope-wl|gamescopereaper|sunshine|bash|systemd|kill-running-g|pgrep|pkill|sleep|sshd|steam-runtime-l|sh|cat)$'
# A process is "the running game" if its cwd/cmdline/exe path matches.
PATTERN='steamapps[/\\]+(common|compatdata)[/\\]|reaper SteamLaunch|wine[0-9]*-preloader|wineserver'

# Enumerate matching kai processes. Track pid AND pgid so we can do an atomic
# pgrp-kill where it's safe (catches respawn races during shutdown).
PIDS=""; PGIDS=""
for pid in $(pgrep -u kai); do
  [ -d /proc/$pid ] || continue
  comm=$(cat /proc/$pid/comm 2>/dev/null) || continue
  echo "$comm" | grep -qE "$EXCLUDE" && continue
  cwd=$(readlink /proc/$pid/cwd 2>/dev/null)
  cmd=$(tr "\0" " " </proc/$pid/cmdline 2>/dev/null)
  exe=$(readlink /proc/$pid/exe 2>/dev/null)
  if echo "$cwd|$cmd|$exe" | grep -qiE "$PATTERN"; then
    pgid=$(awk '{print $5}' /proc/$pid/stat 2>/dev/null)
    PIDS="$PIDS $pid"
    [ -n "$pgid" ] && [ "$pgid" != "0" ] && PGIDS="$PGIDS $pgid"
    echo "  match pid=$pid pgid=$pgid comm=$comm cwd=$cwd exe=$exe"
  fi
done

# CRITICAL: filter pgids whose LEADER (process with pid==pgid) is infrastructure.
# Without this filter, srt-bwrap (which inherits gamescope-wl's pgrp because
# Steam never setpgid()s its game wrapper) drags pgid 155287 into the kill list,
# and "kill -- -155287" then nukes gamescope-wl itself, taking the whole stack
# down via BindsTo.
SAFE_PGIDS=""
for pg in $(echo $PGIDS | tr ' ' '\n' | sort -u); do
  leader_comm=$(cat /proc/$pg/comm 2>/dev/null)
  if [ -n "$leader_comm" ] && echo "$leader_comm" | grep -qE "$EXCLUDE"; then
    echo "  skip pgrp pgid=$pg (leader is infra: $leader_comm)"
    continue
  fi
  SAFE_PGIDS="$SAFE_PGIDS $pg"
done

# 1. Atomic pgrp-kill for safe pgids only.
if [ -n "$SAFE_PGIDS" ]; then
  echo "[$(ts)] SIGTERM pgrp:$SAFE_PGIDS"
  for pg in $SAFE_PGIDS; do kill -TERM -- -$pg 2>/dev/null; done
  sleep 4
  SURV_PG=""
  for pg in $SAFE_PGIDS; do
    pgrep -g $pg >/dev/null 2>&1 && SURV_PG="$SURV_PG $pg"
  done
  if [ -n "$SURV_PG" ]; then
    echo "[$(ts)] SIGKILL pgrp survivors:$SURV_PG"
    for pg in $SURV_PG; do kill -KILL -- -$pg 2>/dev/null; done
  fi
fi

# 2. Per-PID SIGTERM+SIGKILL for everything we matched (covers anything in a
#    skipped infra pgrp, e.g. srt-bwrap with pgid==gamescope-wl).
LIVE=""
for pid in $PIDS; do [ -d /proc/$pid ] && LIVE="$LIVE $pid"; done
if [ -n "$LIVE" ]; then
  echo "[$(ts)] SIGTERM pids:$LIVE"
  for pid in $LIVE; do kill -TERM $pid 2>/dev/null; done
  sleep 4
  SURV_PID=""
  for pid in $LIVE; do [ -d /proc/$pid ] && SURV_PID="$SURV_PID $pid"; done
  if [ -n "$SURV_PID" ]; then
    echo "[$(ts)] SIGKILL pid survivors:$SURV_PID"
    for pid in $SURV_PID; do kill -KILL $pid 2>/dev/null; done
  fi
fi

[ -z "$PIDS" ] && echo "[$(ts)] no game processes found"

# 3. Nudge gamescopereaper so it reaps inherited orphan zombies (best-effort —
#    empirically does not always work, but harmless).
GR_PIDS=$(pgrep -u kai -x gamescopereaper)
if [ -n "$GR_PIDS" ]; then
  echo "[$(ts)] SIGCHLD -> gamescopereaper:$GR_PIDS"
  for gr in $GR_PIDS; do kill -CHLD $gr 2>/dev/null; done
fi

echo "[$(ts)] === done ==="
exit 0
