# TODO — Tailscale + Clash Docker gateway

Implementation tracker for
[tailscale-clash-docker-gateway-prd.md](tailscale-clash-docker-gateway-prd.md).

## Phase 1 — 最小 TCP 链路

- [x] 独立部署目录、Compose、持久化 volume（`tailscale-state`、`singbox-cache`）
- [x] Tailscale Exit Node 容器（kernel TUN、`--advertise-exit-node`、无 auth key）
- [x] nftables TCP TPROXY + 策略路由（fwmark 0x1 → table 100）
- [x] sing-box TPROXY 入站 → SOCKS5 出站
- [x] 容器内经 Clash 的出口 IP 与宿主基准一致（实测相同出口 IP）
- [ ] iPhone 实机验证 + Clash Connections 观察（需先完成一次性 Tailscale 登录与管理台批准）

## Phase 2 — UDP 与 DNS

- [x] SOCKS5 UDP Associate 验证：宿主直连 ✓、容器经 `host.docker.internal` ✓（`scripts/socks5_udp_probe.py`）
- [x] 发现并解决 mihomo `BND.ADDR=127.0.0.1` 问题：容器内 socat TCP+UDP mixed-port 别名（无需开启 allow-lan）
- [x] sing-box → Clash 全链路 UDP 实测通过（共享 netns 内 probe 验证）
- [x] UDP TPROXY、DNS 劫持（含 MagicDNS 100.100.100.100）、FakeIP、`*.ts.net` 分流
- [x] DNS 无泄漏路径：上游解析走 TCP 经 Clash，不依赖 UDP，也不触碰本地 ISP DNS
- [x] UDP 降级开关 `BLOCK_QUIC`（默认关闭；实测无需启用）
- [ ] iPhone 实机 DNS 泄漏测试与 QUIC 行为验证

## Phase 3 — 可靠性与安全

- [x] fail-closed：nftables forward 链丢弃所有未经 TPROXY 的 tailscale0 流量
- [x] 健康检查（sing-box 进程、tailscale0、nft 规则、经 Clash 的 204 探测）
- [x] 日志轮转（10 MiB × 3）与资源上限（每容器 0.5 CPU / 256 MiB）
- [x] tailscale 容器重启后 relay 自动重建规则并重连 netns（已实测）
- [x] 最小能力集：仅 `NET_ADMIN`、`NET_RAW`、`/dev/net/tun`，不映射任何端口到公网
- [ ] Tailnet ACL 收紧（管理台操作，示例见 README）
- [ ] 重启矩阵：Docker Desktop 重启、Clash Verge 重启、macOS 重启

## Phase 4 — 常驻运行

- [ ] Docker Desktop 设置登录后启动、Mac 禁止睡眠
- [ ] 24 小时资源与稳定性观察（`docker stats`，AC-6）
- [ ] 按实测结果回调内存/CPU 上限与 UDP 策略

## 首次上线待办（用户操作）

1. `docker compose exec tailscale tailscale up --hostname=clash-gw --advertise-exit-node --accept-dns=false` → 打开打印的 URL 登录
2. Tailscale 管理台：批准 `clash-gw` 为 Exit Node，关闭 key expiry
3. iPhone 选择 `clash-gw`，跑 README「Verify」一节
