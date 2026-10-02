#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

svc gamescope-headless.service active
svc sunshine.service             active
svc sunshine-disconnect-watchdog.service active
for u in gamescope-headless sunshine sunshine-disconnect-watchdog; do svc "$u.service" enabled; done

[ -x /usr/local/sbin/stream-res ] && ok "stream-res installed" || fail "stream-res missing"

# Sunshine listening on its standard ports
for p in 47984 47989 47990 48010; do
  ss -tlnp 2>/dev/null | grep -q ":$p " && ok "Sunshine listening on $p" || fail "port $p not listening"
done

# HDR + HEVC NVENC confirmed
sudo journalctl -u sunshine --since "5 min ago" --no-pager 2>/dev/null \
  | grep -q 'Found HEVC encoder: hevc_nvenc' \
  && ok "HEVC nvenc encoder ready" \
  || warn "no recent NVENC init log (Sunshine may need a client connect to log encoder)"

# ── Game sandbox ─────────────────────────────────────────────────────────────
# in_unit <unit> <script>: run <script> as gamer inside <unit>'s cgroup (IP
# filter) and mount namespace (filesystem fence).
in_unit() {
  local unit="$1" script="$2" pid
  pid=$(systemctl show -p MainPID --value "$unit")
  [ "${pid:-0}" -gt 0 ] || fail "$unit has no main process"
  sudo bash -c 'echo $$ > "/sys/fs/cgroup/system.slice/$1/cgroup.procs" &&
    exec nsenter -t "$2" -m -- setpriv --reuid=gamer --regid=gamer --init-groups -- bash -c "$3"' \
    _ "$unit" "$pid" "$script"
}
# The IP filter drops silently, so "blocked" = answers from the host, times
# out from inside the unit.
tcp() { echo "timeout 4 bash -c 'exec 3<>/dev/tcp/$1/$2' 2>/dev/null && echo OPEN"; }
reachable() { [ "$(in_unit "$1" "$(tcp "$2" "$3")")" = OPEN ]; }
blocked() {
  timeout 4 bash -c "exec 3<>/dev/tcp/$2/$3" 2>/dev/null || fail "probe target $2:$3 unreachable even from the host"
  ! reachable "$1" "$2" "$3"
}

for p in gamescope-wl steam; do
  [ "$(ps -o user= -C "$p" | sort -u | xargs)" = gamer ] && ok "$p runs as gamer" || fail "$p not running as gamer"
done
[ "$(ps -o user= -C sunshine | sort -u | xargs)" = gamer ] && ok "sunshine runs as gamer" || fail "sunshine not running as gamer"
wd=$(systemctl show -p MainPID --value sunshine-disconnect-watchdog.service)
[ "$(ps -o user= -p "$wd" | xargs)" = gamer ] && ok "watchdog runs as gamer" || fail "watchdog not running as gamer"
steam_pid=$(pgrep -u gamer -x steam | head -1)
ps -o supgrp= -p "$steam_pid" | grep -qw wheel && fail "steam has wheel" || ok "steam has no wheel group"

pads=$(for d in /sys/class/input/event*; do udevadm info -q property "$d" | grep -qx ID_INPUT_JOYSTICK=1 && echo "/dev/input/${d##*/}"; done; true)
if [ -z "$pads" ]; then
  warn "no gamepad present (connect a Moonlight client to check gamepad access)"
else
  for p in $pads; do [ "$(stat -c %U "$p")" = gamer ] && ok "gamer owns gamepad $p" || fail "gamer cannot open gamepad $p"; done
fi
[ "$(stat -c %G /dev/input/event0)" = input ] && [ "$(stat -c %U /dev/input/event0)" = root ] && ok "non-gamepad input stays root:input" || fail "non-gamepad input ownership changed"

GS=gamescope-headless.service
[ "$(in_unit $GS 'ls -A /home')" = gamer ] && ok "games see only /home/gamer" || fail "games can see other homes"
in_unit $GS 'test -r /etc/rancher/k3s/config.yaml' && fail "games can read k3s config" || ok "k3s config hidden from games"
in_unit $GS 'test -r /var/lib/rancher' && fail "games can read /var/lib/rancher" || ok "k3s state hidden from games"
in_unit $GS 'touch /usr/.fence-probe' 2>/dev/null && fail "games can write /usr" || ok "system read-only to games"
[ -z "$(in_unit $GS 'ps -e -o user= | grep -vx gamer')" ] && ok "games see only gamer processes" || fail "games can see other users' processes"
in_unit $GS 'grep -q "^nameserver 1.1.1.1" /etc/resolv.conf' && ok "games use fenced DNS" || fail "games use host DNS"
in_unit $GS 'getent hosts api.steampowered.com >/dev/null' && ok "games resolve internet names" || fail "games cannot resolve names"
reachable $GS 1.1.1.1 443      && ok "games reach the internet"          || fail "games cannot reach the internet"
blocked   $GS 172.16.1.254 80  && ok "games blocked from LAN router"     || fail "games can reach the LAN router"
blocked   $GS 172.16.1.220 8080 && ok "games blocked from gaming-agent"  || fail "games can reach the gaming-agent"
blocked   $GS 10.43.0.1 443    && ok "games blocked from k8s API service" || fail "games can reach the k8s API service"

SS=sunshine.service
[ "$(in_unit $SS 'ls -A /home')" = gamer ] && ok "sunshine sees only /home/gamer" || fail "sunshine can see other homes"
blocked $SS 1.1.1.1 443   && ok "sunshine blocked from the internet"      || fail "sunshine can reach the internet"
blocked $SS 10.43.0.1 443 && ok "sunshine blocked from k8s API service"   || fail "sunshine can reach the k8s API service"
capbnd=$(awk '/^CapBnd/{print $2}' "/proc/$(systemctl show -p MainPID --value $SS)/status")
[ "$capbnd" = 0000000000a00000 ] && ok "sunshine capped to SYS_ADMIN+SYS_NICE" || fail "sunshine capability bound is $capbnd"
