#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../../lib/common.sh"

[ "$(id -u gamer 2>/dev/null)" = 1100 ] && ok "gamer is uid 1100" || fail "gamer missing or not uid 1100"

groups=$(id -nG gamer | tr ' ' '\n' | sort | tr '\n' ' ')
[ "$groups" = "gamer render seat video " ] && ok "gamer groups: $groups" || fail "unexpected gamer groups: $groups"

[ "$(getent passwd gamer | cut -d: -f7)" = /usr/bin/nologin ] && ok "gamer has no login shell" || fail "gamer has a login shell"

case "$(sudo passwd -S gamer | awk '{print $2}')" in
  L|LK|NP) ok "gamer password locked" ;;
  *) fail "gamer has a usable password" ;;
esac

sudo -l -U gamer 2>&1 | grep -q "not allowed to run sudo" && ok "gamer has no sudo rights" || fail "gamer has sudo rights"

[ "$(stat -c '%U %a' /home/gamer)" = "gamer 700" ] && ok "/home/gamer is gamer 700" || fail "/home/gamer ownership/mode wrong"
[ "$(stat -c '%U' /var/log/kill-running-game.log)" = gamer ] && ok "game-kill log owned by gamer" || fail "game-kill log not owned by gamer"
[ -e /var/lib/systemd/linger/gamer ] && ok "gamer lingers (PipeWire runs without a login)" || fail "gamer linger not enabled"
grep -q '^nameserver 1.1.1.1' /etc/gaming-fence/resolv.conf && ok "fenced resolv.conf present" || fail "fenced resolv.conf missing"
