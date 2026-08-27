# network-bridge: Tailscale → Clash transparent exit-node gateway

A resident Docker service for an Apple Silicon Mac that adds a `clash-gw`
exit node to your Tailnet. A remote device (iPhone, laptop) only enables
Tailscale and selects `clash-gw`; all of its TCP, UDP, and DNS traffic then
flows through the Clash Verge instance already running on the Mac — its
rules, subscriptions, and selected proxy node keep working unchanged.

Design rationale, requirements, and acceptance criteria live in
[tailscale-clash-docker-gateway-prd.md](tailscale-clash-docker-gateway-prd.md).

```
iPhone ──tailscale──▶ [tailscale container: kernel TUN]
                          │ nftables TPROXY (tcp+udp+dns)
                          ▼
                      [relay container: sing-box]
                          │ SOCKS5 via 127.0.0.1 alias (socat)
                          ▼
                      host.docker.internal:7897  (Clash Verge mixed-port)
                          ▼
                      Clash rules / selected node ──▶ Internet
```

## Quick start

```sh
./setup.sh
```

One idempotent command: checks prerequisites, builds and starts the stack,
walks you through the one-time Tailscale login, then verifies the whole
TCP + UDP data path. Re-run it any time to update or re-verify. The
sections below cover the same steps manually, plus operations details.

## Prerequisites

- A Docker host, running and set to start at login (the reference
  deployment is Docker Desktop on an Apple Silicon Mac; see
  [Portability](#portability) for plain Linux engines).
- A local proxy with a SOCKS5 port supporting UDP ASSOCIATE — Clash Verge
  with mixed-port `7897` by default (`allow-lan` can stay `false` on
  Docker Desktop).
- A Tailscale account with admin access to approve exit nodes (or a
  self-hosted Headscale — set `TS_LOGIN_SERVER` in `.env`).

## Configure

Defaults work for the standard setup. To override, copy `.env.example` to
`.env` and edit (`CLASH_SOCKS_HOST/PORT`, `TPROXY_PORT`, `BLOCK_QUIC`).
No secrets are stored in this repo, the compose file, or the image.

## First deployment (manual — `./setup.sh` does all of this)

```sh
docker compose up -d --build

# One-time interactive Tailscale login (no auth key is stored anywhere):
docker compose exec tailscale tailscale up \
    --hostname=clash-gw --advertise-exit-node --accept-dns=false
# open the printed https://login.tailscale.com/a/... URL and log in;
# the command returns once the login completes
```

Then in the [Tailscale admin console](https://login.tailscale.com/admin/machines):

1. The node `clash-gw` appears — approve **Use as exit node** (and disable
   key expiry for unattended operation).
2. Optional hardening — **DNS settings → Global nameservers**: with no
   tailnet resolver configured, exit-node clients send DNS to the gateway's
   tailscaled over the Tailscale peer API, which resolves via the host Mac
   where Clash's FakeIP DNS answers it. That path works (mihomo maps its
   own fake IPs back to domains when the connections come back through the
   SOCKS upstream), but it depends on Clash TUN/FakeIP being active on the
   host and can surface `dns-forward-failing` if that chain is flaky. To
   move client DNS fully onto the gateway's own hijack instead, add a
   plain-DNS global nameserver (e.g. `114.114.114.114`) and enable
   **Override DNS servers** — the resolver IP is never actually consulted
   while on the exit node, so pick one that also works for your devices
   when off it, and avoid Tailscale's known-DoH resolvers
   (1.1.1.1/8.8.8.8), which get silently upgraded to DoH and bypass the
   hijack.
3. Optionally restrict who may use it, e.g. in the ACL policy:

   ```jsonc
   "autoApprovers": {"exitNode": ["your-login@example.com"]},
   "acls": [
     {"action": "accept", "src": ["your-login@example.com"],
      "dst": ["autogroup:internet:*"]}
   ]
   ```

On the iPhone: Tailscale app → Exit Node → select `clash-gw`. Nothing else
(no Clash app, no proxy settings, no subscription import) is needed.

Login state persists in the `tailscale-state` volume, so restarts of
Docker/the Mac never ask for login again.

## Verify

```sh
sh scripts/diagnose.sh
```

This prints container health, tailscale status, nftables counters (which
show whether traffic is actually entering TPROXY), the sing-box listener,
and the exit IP fetched through Clash from both the host and the container
(the two must match — that IP is also what the iPhone should see on an IP
echo site while using the exit node).

SOCKS5 UDP ASSOCIATE (QUIC and other UDP through Clash):

```sh
docker compose --profile test run --rm udp-probe        # from inside Docker
python scripts/socks5_udp_probe.py --port 7897          # from the host
```

Both were verified working in this environment. If the probe fails in your
environment, set `BLOCK_QUIC=true` in `.env` and `docker compose up -d`:
UDP/443 is then rejected so HTTP/3 clients fall back to TCP immediately.
DNS never depends on UDP upstream (see below), so it stays leak-free
either way.

## How it works

- **tailscale container** runs kernel-TUN tailscaled (`/dev/net/tun`,
  `NET_ADMIN`/`NET_RAW`, no `--privileged`) and advertises itself as an
  exit node named `clash-gw`.
- **relay container** shares the tailscale container's network namespace.
  nftables marks TCP/UDP arriving on `tailscale0` and TPROXYes it into
  sing-box (`:7893`); policy routing (`fwmark 0x1 → table 100`) delivers
  it locally.
- **DNS**: all client port-53 traffic — including MagicDNS
  `100.100.100.100` — is hijacked into sing-box. `*.ts.net` names are
  forwarded to MagicDNS directly; everything else is answered from a
  **FakeIP** range (`198.18.0.0/15`, `fc00::/18`). When the client then
  connects to a fake IP, sing-box hands Clash the original **domain**, so
  Clash domain rules and remote resolution work exactly as if the request
  had been made locally. Real upstream lookups go over TCP through Clash —
  no resolver on the gateway's ISP is ever consulted. The FakeIP range is
  `198.19.0.0/16`, deliberately disjoint from mihomo's `198.18.0.0/16`, so
  answers from the two FakeIP engines can never be confused.
- **UDP**: Clash answers SOCKS5 UDP ASSOCIATE with `BND.ADDR=127.0.0.1`
  (mixed-port on loopback, `allow-lan: false`), which is unreachable from
  another network namespace. The relay therefore runs a socat TCP+UDP
  alias of the mixed-port on its own `127.0.0.1:7897`, making that reply
  address valid inside the container. This keeps `allow-lan` off.
- **Fail-closed**: an nftables `forward` rule drops everything arriving
  from `tailscale0` that was not delivered via TPROXY. If sing-box or
  Clash dies, client traffic fails — it is never silently NATed out the
  Mac's own connection. (Side effect: ICMP ping through the exit node does
  not work; SOCKS5 cannot carry it anyway.)
- **Recovery**: `restart: unless-stopped` everywhere; a watchdog restarts
  the relay if sing-box/socat dies or the tailscale container was
  recreated (verified: rules and listeners re-apply automatically).
  Healthchecks probe the full chain including an HTTP fetch through the
  Clash mixed-port every 30 s (visible as a small periodic entry in Clash
  Connections).

## Operations

- Logs: `docker compose logs -f relay` / `... tailscale`
  (json-file, 10 MiB × 3 rotation).
- Resources: `docker stats` — each container is capped at 0.5 CPU /
  256 MiB (adjust in `docker-compose.yml` after performance testing).
- Update images: bump the pinned tags in `docker-compose.yml` /
  `gateway/Dockerfile`, then `docker compose up -d --build`.
- Prevent the Mac from sleeping (System Settings → Energy) or the exit
  node goes offline.

## Portability

Everything device-specific is meant to live in `.env` (`.env.example`
documents each knob: proxy host/port, node name, TPROXY port, QUIC
fallback, Headscale URLs). Notes for setups other than the reference one:

- **Plain Linux Docker engine**: `host.docker.internal` is mapped to
  `host-gateway` by the compose file, but Linux does not forward container
  traffic to host **loopback** the way Docker Desktop does — the proxy
  must listen beyond `127.0.0.1` (Clash `allow-lan: true`), with the host
  firewall restricting the port to the Docker subnet.
- **Other proxies**: any local SOCKS5 endpoint with UDP ASSOCIATE works as
  the upstream; only `CLASH_SOCKS_HOST/PORT` change. If the host proxy
  runs its own FakeIP TUN, its range must stay disjoint from the gateway's
  `198.19.0.0/16` (mihomo's default `198.18.0.0/16` already is).
- **Headscale**: set `TS_LOGIN_SERVER` (and optionally `TS_ADMIN_URL`) in
  `.env`; `setup.sh` passes them through.
- **Node name**: `GW_NODE_NAME` in `.env` (default `clash-gw`).

For Claude Code users, `.claude/skills/gateway-setup/SKILL.md` packages
the whole procedure — environment detection, configuration, verification,
and a symptom→cause→fix map of every failure mode debugged on the
reference deployment — as a `/gateway-setup` skill available after
cloning this repo.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Node missing from Tailnet | `docker compose logs tailscale` — login URL not visited yet, or key expired |
| iPhone selects node but no traffic | nft counters in `scripts/diagnose.sh` all zero → Tailscale admin hasn't approved exit node |
| TCP works, some apps hang | QUIC/UDP path: run the UDP probes; consider `BLOCK_QUIC=true` |
| Everything fails, relay unhealthy | Clash Verge not running / mixed-port changed — fix and the gateway recovers on its own |
| Domains hit wrong Clash rules | Client cached real IPs from before enabling the exit node — toggle Wi-Fi/airplane mode to flush DNS |
| Relay logs `tailscale0 disappeared` | Normal after tailscale container restart; it rejoins automatically |
| Node warns `could not connect to relay server`, phone says it can't reach DNS servers | Docker Desktop injects the macOS system proxy (set by Clash) into containers, sending tailscaled's DERP/control traffic through the proxy exit. The compose file pins `HTTP(S)_PROXY` empty for the tailscale service — make sure that block is present |
| Relay logs `missing fakeip record`, phone shows `dns-forward-failing` | The relay is seeing FakeIPs it didn't issue with reverse-mapping failing — normally impossible with the disjoint ranges (gateway `198.19.0.0/16` vs mihomo `198.18.0.0/16`); check that the ranges haven't been changed to overlap, and consider the tailnet **global nameserver + Override DNS servers** hardening (see First deployment) |

## Rollback

1. Deselect the exit node on the iPhone.
2. `docker compose down` (add `-v` only when you also want to drop the
   Tailscale login state).
3. Disable or remove `clash-gw` in the Tailscale admin console.

Nothing on the host Mac (Tailscale client, Clash Verge, its subscriptions)
is modified by deploying or rolling back this gateway.

## License

[MIT](LICENSE).
