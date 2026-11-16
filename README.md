# 校园网网络修复工具

这个工具用于电脑已经连上校园 Wi‑Fi，但网页打不开、弹不出认证页面、DNS 异常或代理残留的情况。

---

## macOS 使用方法

把 [`scripts/fix_net.command`](scripts/fix_net.command) 复制到桌面（或直接双击仓库里的 `scripts/fix_net.command`）：

- **如果本机代理与 IP 正常**：免密码秒查状态，若当前需要校园网认证会直接给出 **登录地址**，按提示即可用浏览器打开登录；
- **如果检测到代理残留 / 未获取有效 IP / DNS 异常**：自动请求管理员权限并依次执行：
  1. 关闭 macOS 系统代理（HTTP / HTTPS / SOCKS / 自动发现 / PAC）；
  2. 清理代理地址、端口和 PAC 配置；
  3. 刷新 DNS 缓存；
  4. 清理 ARP 缓存；
  5. 确认 `Wi-Fi` 使用 DHCP 并触发续租；
  6. 校验已拿到有效 IP 后探测校园网 **登录地址**，并询问是否加入开机启动（`LaunchDaemon`）。

如果之前加入了开机启动，可以在终端运行：

```bash
bash scripts/fix_net.command --remove-startup
```

> 进阶参数（按需使用）：`--fix`（跳过预检直接修复）、`--reset-dns`（同时清除手动 DNS 恢复自动获取）、`--hard`（强制重启接口重连）、`--diagnose`（完整 L1–L5 断网排障报告）。

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
