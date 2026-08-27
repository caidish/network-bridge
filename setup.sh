#!/bin/sh
# One-command setup for the clash-gw transparent exit-node gateway.
# Idempotent: safe to re-run any time — it updates the containers, skips
# login when already authenticated, and re-verifies the data path.
set -u
cd "$(dirname "$0")"

[ -f .env ] && . ./.env
CLASH_SOCKS_PORT="${CLASH_SOCKS_PORT:-7897}"
NODE_NAME="clash-gw"
ADMIN_URL="https://login.tailscale.com/admin/machines"
LOGIN_DONE=0

step() { printf '\n[%s/6] %s\n' "$1" "$2"; }
ok()   { printf '  + %s\n' "$1"; }
warn() { printf '  ! %s\n' "$1"; }
die()  { printf '  x %s\n' "$1" >&2; exit 1; }

ts() { docker compose exec tailscale tailscale "$@"; }
get_state() {
    ts status --json 2>/dev/null | grep -m1 '"BackendState"' \
        | sed 's/[^:]*: *"\([^"]*\)".*/\1/'
}

step 1 "Checking prerequisites"
command -v docker >/dev/null 2>&1 || die "docker not found — install Docker Desktop first"
docker info >/dev/null 2>&1 || die "Docker daemon not running — start Docker Desktop"
ok "Docker is running"
if curl -fsS --max-time 8 -o /dev/null \
        --socks5-hostname "127.0.0.1:${CLASH_SOCKS_PORT}" \
        http://cp.cloudflare.com/generate_204 2>/dev/null; then
    ok "Clash mixed-port ${CLASH_SOCKS_PORT} reachable and proxying"
else
    warn "Clash mixed-port 127.0.0.1:${CLASH_SOCKS_PORT} is not answering."
    warn "Start Clash Verge (mixed-port ${CLASH_SOCKS_PORT}; allow-lan may stay off)."
    warn "Continuing — the gateway stays fail-closed until Clash is up."
fi

step 2 "Building and starting containers"
docker compose up -d --build || die "docker compose up failed"
ok "Stack is up"

step 3 "Tailscale login"
i=0
state=$(get_state)
while [ -z "$state" ] && [ $i -lt 15 ]; do
    i=$((i + 1)); sleep 2; state=$(get_state)
done
[ -z "$state" ] && die "tailscaled did not come up — see: docker compose logs tailscale"
if [ "$state" = "Running" ]; then
    ts set --hostname="$NODE_NAME" --advertise-exit-node --accept-dns=false 2>/dev/null \
        || warn "could not re-assert node settings (check manually)"
    ok "Already logged in"
    LOGIN_DONE=1
else
    printf '  One-time login: open the URL printed below, authenticate, then wait here.\n'
    # SETUP_LOGIN_TIMEOUT (e.g. "10s") is for non-interactive testing only.
    if ts up --hostname="$NODE_NAME" --advertise-exit-node --accept-dns=false \
            ${SETUP_LOGIN_TIMEOUT:+--timeout=$SETUP_LOGIN_TIMEOUT}; then
        ok "Logged in — state persists across restarts"
        LOGIN_DONE=1
    else
        warn "Login not completed. The gateway keeps running, but the node"
        warn "won't join your tailnet until you log in: re-run ./setup.sh"
    fi
fi

step 4 "Waiting for gateway health"
i=0
until [ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' clash-gw-relay 2>/dev/null)" = "healthy" ]; do
    i=$((i + 1))
    if [ $i -gt 30 ]; then
        docker compose logs --tail 10 relay
        die "relay not healthy after 90s — see logs above (is Clash proxying?)"
    fi
    sleep 3
done
ok "Relay healthy (TPROXY -> sing-box -> Clash chain verified)"

step 5 "Verifying data path"
gw_ip=$(docker compose exec relay curl -fsS --max-time 12 \
    --socks5-hostname "127.0.0.1:${CLASH_SOCKS_PORT}" https://ifconfig.me/ip 2>/dev/null || true)
base_ip=$(curl -fsS --max-time 12 \
    --socks5-hostname "127.0.0.1:${CLASH_SOCKS_PORT}" https://ifconfig.me/ip 2>/dev/null || true)
if [ -n "$gw_ip" ] && [ "$gw_ip" = "$base_ip" ]; then
    ok "TCP exit IP via gateway matches host baseline (${gw_ip})"
elif [ -n "$gw_ip" ]; then
    warn "gateway exit IP ${gw_ip} != host baseline ${base_ip:-n/a} — check Clash"
else
    warn "could not fetch exit IP through the gateway — check Clash"
fi
if docker compose --profile test run --rm udp-probe >/dev/null 2>&1; then
    ok "SOCKS5 UDP ASSOCIATE works — QUIC/UDP will be proxied"
else
    warn "UDP probe failed — set BLOCK_QUIC=true in .env (see README) and re-run"
fi

step 6 "Remaining manual steps"
if [ "$LOGIN_DONE" = "0" ]; then
    printf '  1. Complete the Tailscale login: re-run ./setup.sh\n'
    printf '  2. Approve "%s" as exit node: %s\n' "$NODE_NAME" "$ADMIN_URL"
    printf '  3. iPhone: Tailscale app -> Exit Node -> %s\n' "$NODE_NAME"
else
    approved=$(ts status --json 2>/dev/null | grep -m1 '"ExitNodeOption"' | grep -o 'true\|false')
    if [ "${approved:-false}" = "true" ]; then
        ok "Exit node approved — '${NODE_NAME}' is ready"
        printf '  iPhone: Tailscale app -> Exit Node -> %s\n' "$NODE_NAME"
        printf '  Deeper diagnostics any time: sh scripts/diagnose.sh\n'
    else
        printf '  1. Approve "%s" as exit node: %s\n' "$NODE_NAME" "$ADMIN_URL"
        printf '     (machine menu -> Edit route settings -> Use as exit node;\n'
        printf '      also disable key expiry for unattended operation)\n'
        printf '  2. iPhone: Tailscale app -> Exit Node -> %s\n' "$NODE_NAME"
        printf '  3. Re-run ./setup.sh to confirm, or: sh scripts/diagnose.sh\n'
    fi
fi
