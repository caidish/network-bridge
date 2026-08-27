# Tailscale + Clash Verge Docker 透明出口网关 PRD

- 文档状态：Implemented（部署文件见仓库根目录，操作说明见 README.md）
- 创建日期：2026-08-27
- 目标平台：Apple Silicon macOS + Docker Desktop
- 目标用户：个人 Tailnet 内的 iPhone、Mac 等远程设备

## 1. 背景

当前宿主 Mac（Apple Silicon Mac mini）同时运行 Tailscale macOS 客户端和 Clash Verge。用户希望远程 iPhone 只开启 Tailscale、选择一个 Exit Node 后，全部互联网流量继续经过宿主 Mac 上 Clash Verge 当前选中的代理节点和规则。

直接串联 macOS 上的两个 Network Extension/TUN 不可靠。Tailscale macOS Exit Node 使用 userspace routing，转发流量没有进入 Clash Verge TUN。当前 Clash Verge 内置的 Mihomo `v1.19.25 darwin arm64` 也实测无法提供完整的 Darwin redir 入站：TCP listener 创建后，UDP listener 报 `not supported on current platform`。macOS PF 因此不能实现完整 TCP/UDP 透明网关。

Docker Desktop 内部运行 Linux VM。实测该环境具备 `/dev/net/tun`，并支持 nftables 的 TCP 和 UDP TPROXY，可作为透明转发数据面。

## 2. 产品目标

在宿主 Mac 上运行一个常驻 Docker 服务，为 Tailnet 提供新的 Exit Node `clash-gw`。

远程设备的目标体验：

1. iPhone 只需开启 Tailscale。
2. 在 Tailscale 中选择 `clash-gw` 作为 Exit Node。
3. 无需在 iPhone 安装 Clash、配置系统代理或导入代理订阅。
4. TCP、UDP 和 DNS 流量透明进入 Mac 上现有 Clash Verge。
5. Clash Verge 的规则模式、节点选择和订阅管理继续生效。

## 3. 非目标

- 不修改或重新编译 Tailscale macOS 客户端。
- 不依赖 macOS PF、Mihomo `redir-port` 或 macOS TProxy。
- 不用容器内代理核心替代 Clash Verge 的订阅、规则和节点管理。
- 不向公网暴露 Clash mixed-port 或任何管理端口。
- 不把部署文件混入其他无关仓库。
- 首期不提供多用户控制台、Web UI 或自动节点选择。

## 4. 已验证环境

| 项目 | 当前状态 |
| --- | --- |
| Docker Desktop | `29.2.1`，Linux arm64 |
| Docker TUN | `/dev/net/tun` 可用 |
| nftables TPROXY | TCP、UDP 均通过隔离容器测试 |
| Tailscale macOS | `1.92.3` |
| Clash Verge Mihomo | `v1.19.25 darwin arm64` |
| Clash mixed-port | `7897` |
| Clash 模式 | Rule，TUN 已启用 |
| Docker 到 Clash TCP | `socks5h://host.docker.internal:7897` 已实测可用 |
| Clash Allow LAN | 当前为 `false`；TCP 路径不要求开启 |

## 5. 方案架构

```text
iPhone / Remote Mac
        |
        | Tailscale encrypted tunnel
        v
Docker: clash-gw
  tailscaled (kernel TUN, tailscale0)
        |
        | nftables TPROXY + policy routing
        v
  sing-box transparent relay
        |
        | SOCKS5 TCP/UDP
        v
host.docker.internal:7897
        |
        v
Mac: Clash Verge / Mihomo
        |
        | Existing Clash rules and selected proxy
        v
Internet
```

### 5.1 组件职责

**Tailscale 容器**

- 使用内核 TUN 模式，而非 `TS_USERSPACE=true`。
- 持久化 `/var/lib/tailscale`，避免每次重启重新登录。
- 以 `clash-gw` 为独立 Tailnet 节点。
- 广播 `--advertise-exit-node`。
- 接收 iPhone 的 Exit Node 流量。

**nftables 与策略路由**

- 仅匹配从 `tailscale0` 进入、目标为互联网的流量。
- 排除本机地址、Tailnet 控制流量、组播、广播和保留网段。
- 将 TCP 和 UDP 流量标记并送入本地 TPROXY listener。
- 设置独立 routing table，避免代理回环。

**sing-box 转发层**

- 只承担 Linux TPROXY 入站到 SOCKS5 出站的转换。
- 不保存机场订阅，不负责节点选择。
- 启用 TCP、UDP、DNS 和必要的域名嗅探。
- SOCKS5 上游为 `host.docker.internal:7897`。

**Clash Verge**

- 保持当前 GUI、订阅、Rule/Global 模式和节点选择方式。
- 首先保持 `allow-lan: false`，利用 Docker Desktop 的宿主机转发访问 mixed-port。
- 仅当 UDP 验证证明必须开放 LAN 时才启用 `allow-lan: true`，并同时增加访问限制。

## 6. 功能需求

### FR-1：独立 Exit Node

- Docker 服务启动后，Tailnet 中出现 `clash-gw`。
- 管理员可在 Tailscale 管理后台批准其作为 Exit Node。
- 不覆盖或修改宿主 Mac 现有 Tailscale 节点配置。

### FR-2：透明 TCP 转发

- iPhone 无需设置 HTTP/SOCKS 代理。
- 浏览器、App Store、即时通讯等 TCP 流量进入 Clash Verge。
- Clash Connections 页面能看到对应连接及命中的规则。

### FR-3：透明 UDP 转发

- DNS、QUIC 和普通 UDP 流量经 Linux TPROXY 进入转发层。
- SOCKS5 UDP Associate 必须通过 `host.docker.internal:7897` 实测验证。
- 如果 Clash/Docker 的 SOCKS5 UDP 路径不可用，首期必须明确降级策略：阻断 UDP/443 以强制 HTTP/3 回退，但 DNS 仍需提供无泄漏的代理路径。

### FR-4：DNS 一致性

- iPhone 的 DNS 查询不得绕过透明网关直接访问本地网络或运营商 DNS。
- 域名解析结果应与 Clash 规则兼容。
- 必须避免 Tailscale MagicDNS 和代理 DNS 之间形成循环。

### FR-5：自动恢复

- Docker Desktop 重启后服务自动启动。
- Tailscale 登录状态保留。
- Clash Verge 暂时不可用时，网关应失败关闭，不允许静默直连造成出口泄漏。
- Clash 恢复后，网关无需重新认证即可恢复服务。

## 7. 安全要求

- 不在 Compose 文件、镜像或日志中保存长期 Tailscale auth key。
- 首次部署优先使用一次性交互登录，并持久化 Tailscale state volume。
- 容器只授予必需能力：`NET_ADMIN`、`NET_RAW` 和 `/dev/net/tun`；不使用 `--privileged`。
- sing-box listener 只监听容器共享 network namespace，不映射到 macOS 公网端口。
- 不发布 Tailscale LocalAPI、Clash external-controller 或 Dashboard。
- Tailnet policy 只允许指定用户/设备使用 `clash-gw` 访问 `autogroup:internet`。
- 若必须启用 Clash `allow-lan`，应限制 `7897` 仅允许 Docker/Tailscale 所需来源访问。
- 日志不得输出订阅 URL、认证密钥或代理凭据。

## 8. 资源与运行要求

- Compose 使用 `restart: unless-stopped`。
- 网关初始内存上限设置为 `512 MiB`，稳定后评估降至 `256 MiB`。
- CPU 上限初始设置为 1 个逻辑核心，性能测试不足时再调整。
- Docker 日志使用轮转：单文件 `10 MiB`，最多 3 个文件。
- 预期新增空闲内存为 `50–150 MiB`，空闲 CPU 低于 1%。
- 不限制网络带宽，但记录 10、50、100 Mbps 下的 CPU 和吞吐表现。

## 9. 可观测性

- 提供 Tailscale 状态检查：节点在线、Exit Node 广播有效。
- 提供 sing-box listener 与 SOCKS5 上游健康检查。
- 使用 `docker compose logs` 可区分认证、路由、TPROXY、DNS 和上游连接错误。
- 使用 `docker stats` 查看 CPU、内存和网络吞吐。
- 提供最小诊断命令，能够确认流量是否依次经过 `tailscale0`、TPROXY、sing-box 和 Clash。

## 10. 验收标准

### AC-1：节点可用

- `clash-gw` 在 Tailscale 管理后台在线。
- 节点状态显示可以作为 Exit Node。
- iPhone 能看到并选择该节点。

### AC-2：TCP 出口正确

- 在 Mac 上通过 `socks5h://host.docker.internal:7897` 获取代理出口 IP，记录为基准值。
- iPhone 选择 `clash-gw` 后访问 IP 检测网站，出口 IP与基准一致。
- Clash Connections 中出现来自 Docker 网关的连接。

### AC-3：规则生效

- Clash Verge 切换两个不同代理节点后，iPhone 的公网出口随之改变。
- Clash Verge 切换 Rule/Global 模式后，iPhone 流量行为随之改变。

### AC-4：UDP 与 DNS

- SOCKS5 UDP Associate 通过自动化探针验证。
- iPhone 的 DNS 泄漏测试不显示远端所在地运营商 DNS。
- 支持 UDP 的测试请求成功；若采用 UDP/443 降级，Safari/Chrome 能自动回退到 TCP 且不直连。

### AC-5：恢复能力

- 重启 Docker Desktop 后，网关自动恢复且无需重新登录 Tailscale。
- 重启 Clash Verge 后，网关自动恢复。
- 停止网关 Compose 后，iPhone 无法通过该 Exit Node 意外直连互联网。

### AC-6：性能

- 日常浏览延迟可接受，无持续单核满载。
- 50 Mbps 持续传输 10 分钟无明显丢包、内存持续增长或容器重启。
- 空闲 30 分钟后，两个网关组件合计内存目标低于 `200 MiB`。

## 11. 实施阶段

### Phase 1：最小 TCP 链路

- 创建独立部署目录、Compose 和持久化 volume。
- 启动 Tailscale Exit Node。
- 配置 nftables TCP TPROXY 和 sing-box SOCKS5 出站。
- 完成 TCP 出口 IP 与 Clash Connections 验证。

### Phase 2：UDP 与 DNS

- 验证 Clash mixed-port 的 SOCKS5 UDP Associate。
- 增加 UDP TPROXY、DNS 劫持和防泄漏规则。
- 验证 QUIC、DNS 和普通 UDP。

### Phase 3：可靠性与安全

- 增加健康检查、fail-closed、日志轮转和资源限制。
- 收紧 Tailnet policy 与本机端口访问范围。
- 完成 Docker、Clash 和 macOS 重启测试。

### Phase 4：常驻运行

- 配置 Docker Desktop 登录后启动。
- 观察 24 小时资源、连接稳定性和日志。
- 根据实测调整内存、CPU 和 UDP 策略。

## 12. 风险与缓解

| 风险 | 影响 | 缓解措施 |
| --- | --- | --- |
| Docker 到 Clash 的 SOCKS5 UDP 不可用 | QUIC、部分游戏和实时应用失败 | 优先验证 UDP Associate；必要时研究 UoT，或阻断 UDP/443 强制回退 |
| Tailscale 只能通过 DERP 中继 | 延迟升高、吞吐下降 | 检查 NAT/防火墙，优先建立 direct connection |
| Clash 停止后发生直连 | 出口泄漏 | nftables 默认 fail-closed，不配置 DIRECT fallback |
| Tailscale 与 nftables 规则顺序冲突 | 流量未进入 TPROXY | 使用独立 table/chain、明确 hook priority，并在每次启动后自检 |
| Docker Desktop 或 Mac 休眠 | Exit Node 离线 | Mac mini 禁止自动睡眠，Docker 登录后启动 |
| Clash Allow LAN 扩大暴露面 | 局域网设备可使用代理 | 默认保持关闭；若必须开启，配合本机防火墙限制来源 |
| 代理回环 | CPU 飙升、网络中断 | 排除容器自身、Tailscale 控制流量和 SOCKS5 上游目的地址 |

## 13. 回滚方案

1. iPhone 取消选择 `clash-gw` Exit Node。
2. 停止网关 Compose 服务。
3. 在 Tailscale 管理后台禁用或移除 `clash-gw`。
4. 保留 volume 便于排查；确认不再需要后再手动删除。
5. 如果曾开启 Clash `Allow LAN`，恢复为 `false`。

回滚不修改宿主 Mac 原有 Tailscale 节点，也不影响 Clash Verge 的订阅和配置。

## 14. 待验证事项

- Clash Verge 当前 mixed-port 通过 Docker Desktop 的 TCP 已验证；SOCKS5 UDP Associate 尚需验证。
- Docker 内 Tailscale 节点能否与 iPhone 建立 direct connection，需部署后从实际网络测试。
- Tailscale 自动生成的 nftables 规则与自定义 TPROXY chain 的最终优先级需通过抓包确认。
- iOS 不同应用对 QUIC 失败后的 TCP 回退行为需实机验证。
