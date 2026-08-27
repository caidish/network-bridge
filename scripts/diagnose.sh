#!/bin/sh
# Minimal end-to-end diagnostics for the clash-gw transparent gateway
# (PRD section 9). Run on the host Mac from anywhere in the repo.
set -u
cd "$(dirname "$0")/.."

# Pick up CLASH_SOCKS_* overrides if a .env exists.
[ -f .env ] && . ./.env
CLASH_SOCKS_HOST="${CLASH_SOCKS_HOST:-host.docker.internal}"
CLASH_SOCKS_PORT="${CLASH_SOCKS_PORT:-7897}"
IP_ECHO_URL="${IP_ECHO_URL:-https://api.ip.sb/ip}"

C="docker compose"

echo "== containers =="
$C ps

echo
echo "== tailscale node =="
$C exec tailscale tailscale status --peers=false 2>&1 | head -5
echo "(exit-node advertisement/approval is confirmed in the Tailscale admin console)"

echo
echo "== nftables (counters confirm tailscale0 -> TPROXY -> sing-box) =="
$C exec relay nft list table inet clashgw 2>&1

echo
echo "== sing-box TPROXY listener =="
$C exec relay sh -c 'ss -lntup | grep ":${TPROXY_PORT:-7893}" || echo "LISTENER MISSING"'

echo
echo "== container -> Clash mixed-port (exit IP through selected node) =="
$C exec relay curl -fsS --max-time 10 \
    --socks5-hostname "${CLASH_SOCKS_HOST}:${CLASH_SOCKS_PORT}" "$IP_ECHO_URL" \
    || echo "UPSTREAM FAILED (is Clash Verge running with mixed-port ${CLASH_SOCKS_PORT}?)"

echo
echo "== host -> Clash mixed-port baseline (should match the IP above) =="
curl -fsS --max-time 10 --socks5-hostname "127.0.0.1:${CLASH_SOCKS_PORT}" "$IP_ECHO_URL" \
    || echo "BASELINE FAILED"

echo
echo "== resources =="
docker stats --no-stream clash-gw-tailscale clash-gw-relay
