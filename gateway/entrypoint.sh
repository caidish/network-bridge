#!/bin/sh
# Relay entrypoint: waits for tailscale0, renders configs, applies nftables
# TPROXY + policy routing, then runs sing-box with a netns watchdog.
set -eu

CLASH_SOCKS_HOST="${CLASH_SOCKS_HOST:-host.docker.internal}"
CLASH_SOCKS_PORT="${CLASH_SOCKS_PORT:-7897}"
TPROXY_PORT="${TPROXY_PORT:-7893}"
BLOCK_QUIC="${BLOCK_QUIC:-false}"
TPROXY_MARK="0x1"
TPROXY_TABLE="100"

log() { echo "[relay] $*"; }

log "waiting for tailscale0 in shared network namespace ..."
i=0
until ip link show tailscale0 >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -gt 60 ]; then
        log "ERROR: tailscale0 not present after 120s (is the tailscale service up?)"
        exit 1
    fi
    sleep 2
done
log "tailscale0 present"

# Improve exit-node UDP forwarding throughput (tailscale's ethtool advice);
# harmless if the driver does not support it.
ethtool -K eth0 rx-udp-gro-forwarding on rx-gro-list off 2>/dev/null \
    && log "eth0 UDP GRO forwarding enabled" \
    || log "eth0 GRO tuning not supported (ok)"

# Clash (mihomo) answers SOCKS5 UDP ASSOCIATE with BND.ADDR=127.0.0.1:port
# (mixed-port bound to loopback, allow-lan=false) and sing-box sends UDP
# datagrams to that address verbatim. A container-local TCP+UDP alias of the
# mixed-port makes 127.0.0.1:port valid inside this netns, so UDP works
# without enabling allow-lan on the host.
SOCAT_TCP_PID=""
SOCAT_UDP_PID=""
SB_UPSTREAM_HOST="$CLASH_SOCKS_HOST"
if [ "$CLASH_SOCKS_HOST" != "127.0.0.1" ]; then
    socat -T 300 "TCP4-LISTEN:${CLASH_SOCKS_PORT},bind=127.0.0.1,fork,reuseaddr" \
        "TCP4:${CLASH_SOCKS_HOST}:${CLASH_SOCKS_PORT}" &
    SOCAT_TCP_PID=$!
    socat -T 300 "UDP4-LISTEN:${CLASH_SOCKS_PORT},bind=127.0.0.1,fork,reuseaddr" \
        "UDP4:${CLASH_SOCKS_HOST}:${CLASH_SOCKS_PORT}" &
    SOCAT_UDP_PID=$!
    SB_UPSTREAM_HOST="127.0.0.1"
    log "mixed-port alias 127.0.0.1:${CLASH_SOCKS_PORT} -> ${CLASH_SOCKS_HOST}:${CLASH_SOCKS_PORT} (TCP+UDP)"
fi

mkdir -p /etc/sing-box /var/lib/sing-box
sed -e "s/__CLASH_HOST__/${SB_UPSTREAM_HOST}/g" \
    -e "s/__CLASH_PORT__/${CLASH_SOCKS_PORT}/g" \
    -e "s/__TPROXY_PORT__/${TPROXY_PORT}/g" \
    /opt/clashgw/sing-box.json.tmpl >/etc/sing-box/config.json

if [ "$BLOCK_QUIC" = "true" ]; then
    # FR-3 fallback: reject UDP/443 so HTTP/3 clients fall back to TCP.
    # DNS is unaffected (answered locally via FakeIP / proxied over TCP).
    log "BLOCK_QUIC=true: rejecting UDP/443 from tailscale0"
    jq '.route.rules |= [{"inbound":["tproxy-in"],"network":"udp","port":[443],"action":"reject"}] + .' \
        /etc/sing-box/config.json >/tmp/config.json
    mv /tmp/config.json /etc/sing-box/config.json
fi

sing-box check -c /etc/sing-box/config.json
log "sing-box config OK (upstream socks5://${SB_UPSTREAM_HOST}:${CLASH_SOCKS_PORT}, tproxy :${TPROXY_PORT})"

sed -e "s/__TPROXY_PORT__/${TPROXY_PORT}/g" \
    /opt/clashgw/nftables.nft.tmpl >/tmp/clashgw.nft
nft -f /tmp/clashgw.nft
log "nftables TPROXY + fail-closed rules applied"

while ip rule del fwmark "$TPROXY_MARK" lookup "$TPROXY_TABLE" 2>/dev/null; do :; done
ip rule add fwmark "$TPROXY_MARK" lookup "$TPROXY_TABLE" pref 100
ip route replace local default dev lo table "$TPROXY_TABLE"
while ip -6 rule del fwmark "$TPROXY_MARK" lookup "$TPROXY_TABLE" 2>/dev/null; do :; done
ip -6 rule add fwmark "$TPROXY_MARK" lookup "$TPROXY_TABLE" pref 100
ip -6 route replace local default dev lo table "$TPROXY_TABLE"
log "policy routing ready (fwmark ${TPROXY_MARK} -> table ${TPROXY_TABLE})"

sing-box run -c /etc/sing-box/config.json &
SB_PID=$!
trap 'kill "$SB_PID" $SOCAT_TCP_PID $SOCAT_UDP_PID 2>/dev/null; wait "$SB_PID" 2>/dev/null; exit 0' TERM INT

# Watchdog: exit (and let Docker restart us) if any component dies or the
# shared netns was recreated (tailscale container restarted -> no tailscale0).
while :; do
    for pid in "$SB_PID" $SOCAT_TCP_PID $SOCAT_UDP_PID; do
        if ! kill -0 "$pid" 2>/dev/null; then
            log "component (pid $pid) exited; restarting container"
            kill "$SB_PID" $SOCAT_TCP_PID $SOCAT_UDP_PID 2>/dev/null
            exit 1
        fi
    done
    if ! ip link show tailscale0 >/dev/null 2>&1; then
        log "tailscale0 disappeared; restarting container to rejoin netns"
        kill "$SB_PID" $SOCAT_TCP_PID $SOCAT_UDP_PID 2>/dev/null
        exit 1
    fi
    sleep 5
done
