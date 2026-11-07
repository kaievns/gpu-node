#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

svc gamescope-headless.service active
svc sunshine.service             active
svc sunshine-disconnect-watchdog.service active
for u in gamescope-headless sunshine sunshine-disconnect-watchdog; do svc "$u.service" enabled; done

[ -x /usr/local/sbin/stream-res ] && ok "stream-res installed" || fail "stream-res missing"
grep -rqs "gamescope-headless/resolution" /etc/tmpfiles.d /usr/lib/tmpfiles.d /run/tmpfiles.d \
  && fail "a tmpfiles rule still clears stream-res pins at boot" || ok "stream-res pins survive reboots"

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
# in_unit <unit> <script>: run <script> as gamer in the cgroup (IP filter) and
# mount namespace (filesystem fence) <unit>'s main process really runs in. For
# gamescope that's a PAM session scope, not the unit's own cgroup.
in_unit() {
  local unit="$1" script="$2" pid cg
  pid=$(systemctl show -p MainPID --value "$unit")
  [ "${pid:-0}" -gt 0 ] || fail "$unit has no main process"
  cg=$(sudo sed 's/^0:://' "/proc/$pid/cgroup")
  sudo bash -c 'echo $$ > "/sys/fs/cgroup$1/cgroup.procs" &&
    exec nsenter -t "$2" -m -- setpriv --reuid=gamer --regid=gamer --init-groups -- bash -c "$3"' \
    _ "$cg" "$pid" "$script"
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
strays=$(for p in $(pgrep -u gamer); do sudo cat "/proc/$p/cgroup" 2>/dev/null; done | sed 's/^0:://' | sort -u \
  | grep -vE '^/user\.slice/user-1100\.slice/|^/system\.slice/(sunshine|sunshine-disconnect-watchdog)\.service$' || true)
[ -z "$strays" ] && ok "every gamer process runs in a fenced cgroup" || fail "gamer processes outside the fence: $strays"

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
in_unit $GS 'exec 3<>/dev/uinput' && ok "Steam can create virtual controllers (uinput)" || fail "Steam cannot open /dev/uinput"
in_unit $GS 'findmnt -no OPTIONS /proc' | grep -q hidepid && fail "games' /proc has hidepid (breaks EasyAntiCheat)" || ok "games' /proc has no hidepid (EasyAntiCheat needs it)"
sudo nmcli general reload dns-rc
in_unit $GS 'cat /etc/resolv.conf' | cmp -s - /etc/gaming-fence/resolv.conf \
  && ok "games use fenced DNS, even after a NetworkManager DNS update" || fail "games lost the fenced resolv.conf"
in_unit $GS 'getent hosts api.steampowered.com >/dev/null' && ok "games resolve internet names" || fail "games cannot resolve names"
reachable $GS 1.1.1.1 443      && ok "games reach the internet"          || fail "games cannot reach the internet"
blocked   $GS 172.16.1.254 80  && ok "games blocked from LAN router"     || fail "games can reach the LAN router"
blocked   $GS 172.16.1.220 8080 && ok "games blocked from gaming-agent"  || fail "games can reach the gaming-agent"
blocked   $GS 10.43.0.1 443    && ok "games blocked from k8s API service" || fail "games can reach the k8s API service"
bcast=$(in_unit $GS "python3 -c 'import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
try:
    s.sendto(b\"x\", (\"255.255.255.255\", 9))
    print(\"SENT\")
except PermissionError:
    print(\"DENIED\")'")
[ "$bcast" = DENIED ] && ok "games blocked from LAN broadcast" || fail "games can broadcast on the LAN ($bcast)"

SS=sunshine.service
[ "$(in_unit $SS 'ls -A /home')" = gamer ] && ok "sunshine sees only /home/gamer" || fail "sunshine can see other homes"
blocked $SS 1.1.1.1 443   && ok "sunshine blocked from the internet"      || fail "sunshine can reach the internet"
blocked $SS 10.43.0.1 443 && ok "sunshine blocked from k8s API service"   || fail "sunshine can reach the k8s API service"
capbnd=$(awk '/^CapBnd/{print $2}' "/proc/$(systemctl show -p MainPID --value $SS)/status")
[ "$capbnd" = 0000000000a00000 ] && ok "sunshine capped to SYS_ADMIN+SYS_NICE" || fail "sunshine capability bound is $capbnd"

# ── Per-client mode switching ────────────────────────────────────────────────
/usr/local/bin/stream-mode --self-test >/dev/null && ok "stream-mode picker self-test passes" || fail "stream-mode self-test fails"
sudo grep -qa "GAMESCOPE_MODE_SAVE_FILE=" "/proc/$(systemctl show -p MainPID --value $GS)/environ" \
  && ok "gamescope reads the per-client mode file" || fail "gamescope started without GAMESCOPE_MODE_SAVE_FILE"
sudo grep -q '^global_prep_cmd = .*"do":"/usr/local/bin/stream-mode".*"undo":"/usr/local/bin/stream-mode --default"' /home/gamer/.config/sunshine/sunshine.conf \
  && ok "Sunshine runs stream-mode on connect and --default on session end" || fail "Sunshine global_prep_cmd missing or incomplete"
default=$(grep -oP 'DEFAULT_MODE = \(\K[0-9, ]+' /usr/local/bin/stream-mode | tr -d ' ' | sed 's/,/x/; s/,/@/')
grep -q "modes.cfg .* SAMSUNG:${default}\$" /etc/tmpfiles.d/gamer.conf \
  && ok "boot default matches stream-mode default ($default)" || fail "tmpfiles boot mode differs from stream-mode DEFAULT_MODE ($default)"
last=$(sudo journalctl -u sunshine -b --no-pager -o cat | grep -E "CLIENT (CONNECTED|DISCONNECTED)" | tail -1) || true
if [ -e /etc/gamescope-headless/resolution ]; then
  warn "mode pinned by stream-res; skipping the live switch test"
elif [[ "$last" == *"CLIENT CONNECTED"* ]]; then
  warn "a client is connected; skipping the live switch test"
else
  for m in "1280 800 90 1280 800 90" "1920 1200 120 1920 1200 90"; do
    set -- $m
    out=$(in_unit $SS "SUNSHINE_CLIENT_WIDTH=$1 SUNSHINE_CLIENT_HEIGHT=$2 SUNSHINE_CLIENT_FPS=$3 /usr/local/bin/stream-mode")
    [[ "$out" == *"-> ($4, $5, $6), switched"* || "$out" == *"-> ($4, $5, $6), already active"* ]] \
      && ok "live switch: client ${1}x${2}@${3} gets ${4}x${5}@${6}" || fail "live switch for ${1}x${2}@${3}: $out"
  done
fi

# ── HDR / SDR ────────────────────────────────────────────────────────────────
/usr/local/bin/stream-hdr --self-test >/dev/null && ok "stream-hdr policy self-test passes" || fail "stream-hdr self-test fails"
sudo grep -q '"do":"/usr/local/bin/stream-hdr","undo":"/usr/local/bin/stream-hdr --default"' /home/gamer/.config/sunshine/sunshine.conf \
  && ok "Sunshine runs stream-hdr on connect and --default on session end" || fail "Sunshine global_prep_cmd lacks stream-hdr"
sudo grep -qaF "Running script file '/etc/gamescope/scripts/50-stream-hdr.lua'" /home/gamer/.local/state/gamescope-headless.log \
  && ok "gamescope loaded the stream-hdr display profile" || fail "gamescope did not load 50-stream-hdr.lua"
hdr_prop() { in_unit $SS "DISPLAY=:0 xprop -root $1" | grep -o '[0-9]*$'; }
hdr_out() { echo "$(hdr_prop GAMESCOPE_DISPLAY_SUPPORTS_HDR)$(hdr_prop GAMESCOPE_HDR_OUTPUT_FEEDBACK)"; }
if [ -e /etc/gamescope-headless/hdr ]; then
  warn "HDR policy is '$(cat /etc/gamescope-headless/hdr)'; skipping the SDR default and live HDR tests"
elif [ "$(hdr_out)" != 00 ]; then
  fail "no HDR policy but gamescope offers or outputs HDR ($(hdr_out))"
else
  ok "stream output is SDR by default"
  last=$(sudo journalctl -u sunshine -b --no-pager -o cat | grep -E "CLIENT (CONNECTED|DISCONNECTED)" | tail -1) || true
  if [[ "$last" == *"CLIENT CONNECTED"* ]]; then
    warn "a client is connected; skipping the live HDR test"
  else
    trap 'sudo rm -f /etc/gamescope-headless/hdr; in_unit $SS "/usr/local/bin/stream-hdr --default" >/dev/null' EXIT
    sudo mkdir -p /etc/gamescope-headless
    echo auto | sudo tee /etc/gamescope-headless/hdr >/dev/null
    out=$(in_unit $SS "SUNSHINE_CLIENT_HDR=true /usr/local/bin/stream-hdr")
    case "$out" in
      *"-> HDR, switched"*) ok "live switch to HDR for an HDR client" ;;
      *"Steam's own HDR setting is off"*) warn "HDR allowed but Steam's Display > HDR setting is off" ;;
      *) fail "live switch to HDR: $out" ;;
    esac
    out=$(in_unit $SS "SUNSHINE_CLIENT_HDR=false /usr/local/bin/stream-hdr")
    [[ "$out" == *"-> SDR, switched"* && "$(hdr_out)" == 00 ]] && ok "live switch back to SDR for an SDR client" || fail "live switch to SDR: $out"
    sudo rm -f /etc/gamescope-headless/hdr
    trap - EXIT
  fi
fi
