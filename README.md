# 校园网网络修复工具

这个工具用于电脑已经连上校园 Wi‑Fi，但网页打不开、DNS 解析异常、系统代理残留或 DHCP 租约未恢复的情况。

脚本只负责恢复本机网络环境，不负责校园网账号登录，也不会自动打开认证页面。登录页面由你自己打开和操作。

---

## macOS 使用方法

### 1. 直接运行（推荐）

方式一（访达 / 桌面双击）：

- 在项目目录下双击 [`scripts/fix_net.command`](scripts/fix_net.command)，在弹出的终端中按提示输入开机密码（支持触控 ID）。
- 如果想把独立启动脚本放到桌面，先在终端运行：

```bash
bash scripts/fix_net.sh --install-desktop
```

之后直接双击桌面上的 `fix_net.command` 即可。

方式二（终端命令行）：

```bash
bash scripts/fix_net.sh
```

脚本会依次执行以下操作：

1. 关闭所有已启用网络服务的 macOS 系统代理（HTTP / HTTPS / SOCKS / 自动代理发现 / PAC）；
2. 清理残留代理地址、端口和 PAC URL；
3. 刷新 DNS 缓存（`dscacheutil -flushcache` + `killall -HUP mDNSResponder`）；
4. 清理目标网卡的 ARP 缓存；
5. 确认目标服务（默认自动识别 `Wi-Fi`）为 DHCP 模式并通过 `scutil --renew` 触发续租；
6. 等待并校验已获取有效的 DHCP IP 与网关，并询问是否加入系统开机启动（`LaunchDaemon`）。

### 2. 断网深度检测（不弹登录页时排查原因，免密码）

- 访达双击 [`scripts/diagnose_net.command`](scripts/diagnose_net.command)（若执行过 `--install-desktop`，桌面也会有 `diagnose_net.command`）；
- 或终端运行：

```bash
bash scripts/fix_net.sh --diagnose

# 同时把检测报告保存下来（方便发给别人或留档）
bash scripts/fix_net.sh --diagnose --save ~/Desktop/net-diagnose.txt
```

检测会只读排查 L1（网卡与 DHCP）、L2（系统代理/后台残留代理进程/虚拟网卡分流）、L3（手动 DNS vs DHCP DNS 对比）、L4（网关可达性与 `captive.apple.com` 302 跳转探测）及 L5（最近 15 分钟苹果系统 `captiveagent` 认证裁决日志）。

### 3. 常用参数

```bash
# 只读状态摘要（不需要管理员权限）
bash scripts/fix_net.sh --status

# 预览将执行的操作，不修改任何系统设置（不需要管理员权限）
bash scripts/fix_net.sh --dry-run

# 若同时想把手动配置的 DNS 恢复为 DHCP 自动获取
bash scripts/fix_net.sh --reset-dns

# 若软续租后仍无有效 IP（或卡在 169.254.x.x），强制开关 Wi-Fi / 接口重连
bash scripts/fix_net.sh --hard

# 移除开机启动项
bash scripts/fix_net.sh --remove-startup
```

> 说明：如本机装有代理软件并开启了 TUN 模式（例如默认路由走 `utun*`）或终端设置了 `http_proxy` 环境变量，脚本会给出提示；若仍打不开校园网认证页，请先暂时关闭代理 TUN 模式再试。

---

## Windows 使用方法

双击桌面上的 `fix_net.bat`，在 Windows 提示时允许管理员权限。脚本会依次完成以下操作：

- 关闭 Windows 系统代理，清理代理地址和 PAC 配置；
- 重置 WinHTTP 代理；
- 刷新 DNS 缓存；
- 清理 ARP 缓存；
- 释放并重新获取 `WLAN` 网卡的 DHCP 租约；
- 询问是否加入当前用户的开机启动。

如果之前加入了开机启动，可以运行：

```bat
fix_net.bat /remove-startup
```
