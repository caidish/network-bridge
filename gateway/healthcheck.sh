#!/bin/sh
# Relay health: sing-box process, tailscale0, nft rules, and upstream Clash
# reachability through the SOCKS5 mixed-port (exercises the selected node).
set -eu

CLASH_SOCKS_HOST="${CLASH_SOCKS_HOST:-host.docker.internal}"
CLASH_SOCKS_PORT="${CLASH_SOCKS_PORT:-7897}"

pgrep -x sing-box >/dev/null
ip link show tailscale0 >/dev/null
nft list table inet clashgw >/dev/null

# Exercise the same upstream path sing-box uses: the container-local
# mixed-port alias when active, the direct address otherwise.
TARGET="${CLASH_SOCKS_HOST}"
[ "$TARGET" != "127.0.0.1" ] && pgrep -x socat >/dev/null && TARGET="127.0.0.1"
curl -fsS --max-time 8 -o /dev/null \
    --socks5-hostname "${TARGET}:${CLASH_SOCKS_PORT}" \
    http://cp.cloudflare.com/generate_204
