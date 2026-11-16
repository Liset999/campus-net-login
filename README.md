# 校园网网络修复工具

这个工具用于电脑已经连上校园 Wi‑Fi，但网页打不开、弹不出认证页面、DNS 异常或代理残留的情况。

macOS 与 Windows 均采用同一套用法：**放到桌面双击即可**。

- **如果本机代理与 IP 正常**：免管理员权限秒检状态，若当前需要校园网认证会直接给出 **登录地址**，按提示即可用浏览器打开登录；
- **如果检测到代理残留 / 未获取有效 IP / 链路异常**：自动请求管理员权限完成 6 步修复（关系统代理、清代理与 PAC、刷 DNS、清 ARP、重取 DHCP 租约），修完后探测并给出校园网 **登录地址**，并询问是否加入开机启动。

---

## macOS 使用方法

把 [`scripts/fix_net.command`](scripts/fix_net.command) 复制到桌面（或直接双击仓库里的 `scripts/fix_net.command`）。

如果之前加入了开机启动，可以在终端运行：

```bash
bash scripts/fix_net.command --remove-startup
```

> 进阶参数（按需使用）：`--fix`（跳过预检直接修复）、`--reset-dns`（同时清除手动 DNS 恢复自动获取）、`--hard`（强制重启接口重连）、`--diagnose`（完整 L1–L5 断网排障报告）。

---

## Windows 使用方法

把 [`scripts/fix_net.bat`](scripts/fix_net.bat) 复制到桌面并双击使用。

如果之前加入了开机启动，可以运行：

```bat
fix_net.bat /remove-startup
```

> 进阶参数（按需使用）：`/fix`（跳过预检直接修复）、`/reset-dns`（同时清除手动 DNS 恢复自动获取）、`/diagnose`（只读检测状态与登录地址）。
