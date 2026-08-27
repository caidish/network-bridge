---
name: gateway-setup
description: Deploy this Tailscale-to-Clash transparent exit-node gateway on a new machine — detect the local environment, fill the device-specific settings, run setup, and debug the known failure modes. Use when setting up this repo on a new host, adapting it to a different proxy / Linux Docker / Headscale, or when the gateway misbehaves (dns-forward-failing, missing fakeip record, relay unhealthy, dead tunnel).
---

# Gateway setup on a new machine

This repo turns a Docker host that already runs a local proxy (Clash Verge /
mihomo / any SOCKS5 with UDP ASSOCIATE) into a Tailscale exit node whose
traffic transparently exits through that proxy. All device-specific state
lives in `.env` (see `.env.example`) plus a one-time interactive
`tailscale up` login — nothing else in the repo should need editing for a
normal deployment. Read README.md first; this skill is the operator's
procedure and the debugging map.

## 1. Detect the environment before touching anything

- **Docker flavor**: `docker info --format '{{.OperatingSystem}}'`
  - *Docker Desktop* (macOS/Windows): `host.docker.internal` natively
    forwards TCP **and UDP** to services bound on host loopback — the proxy
    can keep `allow-lan: false`.
  - *Plain Linux engine*: the compose file maps `host.docker.internal` to
    `host-gateway` (the bridge IP), but Linux has no loopback forwarding:
    the proxy must listen beyond `127.0.0.1` (Clash: `allow-lan: true`,
    then firewall the port to the Docker subnet only).
- **Proxy SOCKS5 port**: verify before deploying —
  `curl -fsS --max-time 8 --socks5-hostname 127.0.0.1:PORT http://cp.cloudflare.com/generate_204`
  (Clash Verge default mixed-port is 7897; other common values 7890, 1080).
  If unknown, probe those or ask the user.
- **Host proxy FakeIP range**: if the host proxy runs TUN with FakeIP
  (mihomo default `198.18.0.0/16`), the gateway's own FakeIP range in
  `gateway/sing-box.json.tmpl` (`198.19.0.0/16`) MUST stay disjoint from
  it. Only adjust if the host proxy uses a nonstandard range that overlaps.
- **Control plane**: Tailscale SaaS by default; for Headscale set
  `TS_LOGIN_SERVER` (and optionally `TS_ADMIN_URL`) in `.env`.

## 2. Configure and deploy

1. `cp .env.example .env`, set `CLASH_SOCKS_PORT` (and `GW_NODE_NAME` if the
   tailnet should see a different node name; `TS_LOGIN_SERVER` for
   Headscale). Defaults are correct for macOS + Clash Verge on 7897.
2. Run `./setup.sh` — idempotent; it checks prerequisites, builds and
   starts the stack, walks the one-time login (prints a URL, waits), then
   verifies relay health, the TCP exit-IP baseline, and SOCKS5 UDP.
3. In the Tailscale admin console: approve the node as **exit node** and
   disable key expiry. Optional DNS hardening: see README "First
   deployment" step 2 (global nameserver + Override DNS servers — use a
   plain resolver NOT on Tailscale's DoH auto-upgrade list).
4. On the client device: Tailscale → Exit Node → select the gateway node
   (NOT the Docker host's own Tailscale node — that bypasses the proxy).

## 3. Verify

- `sh scripts/diagnose.sh` — containers, tailscale state, nftables
  counters, listener, exit IP from container vs host (must match).
- Counters live in `nft list chain inet clashgw prerouting` (run inside
  the relay): zero counters while a client browses = client traffic never
  reaches the gateway (exit node not selected/approved, or dead tunnel).
- UDP: `docker compose --profile test run --rm udp-probe` and
  `python scripts/socks5_udp_probe.py --port <PORT>` on the host.
- Client-side: an IP echo site must show the proxy's exit IP; a DNS leak
  test must not show the gateway ISP's resolvers.

## 4. Known failure modes (all previously hit and root-caused)

| Symptom | Root cause | Fix |
| --- | --- | --- |
| Client says "can't reach the configured DNS servers"; gateway warns about a DERP relay; zero nft counters | Docker Desktop injects the host system proxy (set by the proxy app) into containers; tailscaled then routes control/DERP through the proxy exit, which can't reach the nearby DERP — dead tunnel | Keep the `HTTP(S)_PROXY: ""` pin on the tailscale service in docker-compose.yml (present by default; verify it) |
| Relay logs `missing fakeip record`; every connection dies | Gateway FakeIP range overlaps the host proxy's FakeIP range, so the relay tries (and fails) to reverse-map fake IPs it never issued | Keep ranges disjoint: gateway `198.19.0.0/16` vs mihomo `198.18.0.0/16`. After changing ranges, clear the cache volume (`docker run --rm -v clash-gw_singbox-cache:/c alpine rm -f /c/cache.db`) and restart the relay |
| Client shows `dns-forward-failing` but browsing works | With no tailnet global resolver, client DNS rides the MagicDNS peer-API path: gateway tailscaled → Docker DNS → host resolver → host proxy FakeIP. Functional (the host proxy maps its own fake IPs back to domains) but the long chain can be flaky | Optional hardening in README First-deployment step 2: tailnet global nameserver + Override DNS servers moves all client DNS onto the gateway's own port-53 hijack |
| UDP probe passes on host, fails from container | SOCKS5 UDP ASSOCIATE returns `BND.ADDR=127.0.0.1`, valid only on the host; sing-box uses it verbatim | Handled by the relay's socat TCP+UDP mixed-port alias on container-local `127.0.0.1:<port>`; verify two socat processes exist in the relay |
| tailscale container restart-loops before first login | tailscale/tailscale image containerboot gives no-authkey `tailscale up` a 60 s deadline | Already engineered out: compose runs `tailscaled` directly and login happens via `docker compose exec` (setup.sh does it); don't revert to containerboot env vars |
| Linux: relay healthy=false, upstream connection refused | Proxy bound to loopback only — containers can't reach it through `host-gateway` | Bind the proxy to `0.0.0.0` (Clash `allow-lan: true`) and restrict the port to the Docker subnet with the host firewall |
| Client browses but Clash shows only IPs, domain rules miss | Client cached real IPs from before joining the exit node, or its DNS bypasses port 53 (private DoH) | Toggle Wi-Fi/airplane mode to flush the cache; consider the DNS hardening above; enable the host proxy's sniffer as fallback |

## 5. Where things live

- `docker-compose.yml` — the two services (tailscale netns owner + relay),
  caps, limits, the proxy-env pin, `host-gateway` mapping.
- `gateway/` — relay image: `entrypoint.sh` (socat alias, config render,
  nftables, policy routing, watchdog), `nftables.nft.tmpl` (TPROXY + DNS
  hijack + fail-closed forward drop), `sing-box.json.tmpl` (FakeIP DNS,
  tproxy inbound, SOCKS upstream), `healthcheck.sh`.
- `scripts/` — `diagnose.sh`, `socks5_udp_probe.py`.
- Design rationale and acceptance criteria: the PRD markdown in the repo
  root; operator docs: README.md; progress tracker: TODO.md.
