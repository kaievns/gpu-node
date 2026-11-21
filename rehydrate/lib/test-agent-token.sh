#!/usr/bin/env bash
# Tests for require_agent_token and agent_token_stale in common.sh.
# Run: ./test-agent-token.sh   (exit 0 when every case passes)
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

good=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
other=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
pass=0
failed=0

# expect <name> <wanted exit> <env file> <exported token or -> <snippet>
expect() {
  local name=$1 want=$2 file=$3 exported=$4 snippet=$5 got
  if [ "$exported" = - ]; then
    env -u AGENT_TOKEN ENV_FILE="$file" bash -c ". '$here/common.sh'; $snippet" >/dev/null 2>&1
  else
    AGENT_TOKEN="$exported" ENV_FILE="$file" bash -c ". '$here/common.sh'; $snippet" >/dev/null 2>&1
  fi
  got=$?
  if [ "$got" -eq "$want" ]; then
    pass=$((pass + 1))
  else
    failed=$((failed + 1))
    echo "FAIL: $name (exit $got, want $want)"
  fi
}

echo "AGENT_TOKEN=$good" > "$tmp/good.env"
echo "AGENT_TOKEN=" > "$tmp/empty.env"
echo "AGENT_TOKEN=tooshort" > "$tmp/short.env"
echo "$good" > "$tmp/token.same"
echo "$other" > "$tmp/token.other"

expect "token from .env"                 0 "$tmp/good.env"  -        "require_agent_token; [ \"\$AGENT_TOKEN\" = $good ]"
expect "no .env, nothing exported"       1 "$tmp/none.env"  -        "require_agent_token"
expect "empty value"                     1 "$tmp/empty.env" -        "require_agent_token"
expect "shorter than 32 characters"      1 "$tmp/short.env" -        "require_agent_token"
expect "no .env, exported token"         0 "$tmp/none.env"  "$other" "require_agent_token; [ \"\$AGENT_TOKEN\" = $other ]"
expect ".env wins over exported token"   0 "$tmp/good.env"  "$other" "require_agent_token; [ \"\$AGENT_TOKEN\" = $good ]"
expect "host file holds the token"       1 "$tmp/good.env"  -        "require_agent_token; agent_token_stale '$tmp/token.same'"
expect "host file holds another token"   0 "$tmp/good.env"  -        "require_agent_token; agent_token_stale '$tmp/token.other'"

echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
