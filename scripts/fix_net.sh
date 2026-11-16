#!/usr/bin/env bash
# macOS campus network repair script: disable system proxies, clear proxy/PAC
# config, flush DNS & ARP caches, renew Wi-Fi DHCP lease, and manage startup.

export PATH="${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}:/usr/sbin:/sbin:/usr/bin:/bin"

readonly LABEL="com.campus-net-login.fix-net"
readonly LAUNCH_DAEMONS_DIR="${CAMPUS_NET_LAUNCH_DAEMONS_DIR:-/Library/LaunchDaemons}"
readonly LAUNCH_AGENTS_DIR="${CAMPUS_NET_LAUNCH_AGENTS_DIR:-}"
readonly SUPPORT_DIR="${CAMPUS_NET_SUPPORT_DIR:-/Library/Application Support/campus-net-login}"
readonly INSTALLED_SCRIPT="$SUPPORT_DIR/fix_net.sh"
readonly DAEMON_PLIST="$LAUNCH_DAEMONS_DIR/$LABEL.plist"
readonly LOG_FILE="${CAMPUS_NET_LOG_FILE:-/var/log/campus-net-fix.log}"
readonly DHCP_WAIT_SECONDS="${CAMPUS_NET_DHCP_WAIT_SECONDS:-10}"

ACTION="run"
TARGET_SERVICE=""
TARGET_DEVICE=""
RESET_DNS=0
HARD_DHCP=0
STARTUP_RUN=0
NO_STARTUP_PROMPT=0
PAUSE_ON_EXIT=0
SAVE_PATH=""
RESULT=0

ORIG_ARGS=("$@")
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF_PATH="$SELF_DIR/$(basename "$0")"

if [[ "$(basename "$0")" == *.command ]]; then
    PAUSE_ON_EXIT=1
fi

usage() {
    cat <<'EOF'
校园网网络修复工具 (macOS)

用法：
  fix_net.sh [选项]

选项：
  --status              只读诊断当前 Wi-Fi、代理、DNS、ARP 与开机启动状态
  --diagnose            断网深度检测（L1-L5 全链路排查、302 跳转探测与系统认证日志）
  --save <文件>         将 --diagnose / --status 输出额外保存到指定文件
  --dry-run             预览将执行的操作，不修改任何系统设置
  --service <名称>      指定网络服务名（默认自动识别 Wi-Fi，其次默认路由接口）
  --device <接口>       指定网卡设备名（如 en0）
  --reset-dns           同时清除手动 DNS，恢复为 DHCP 自动获取 DNS
  --hard                若软续租未获取到有效 IP，强制重启接口/Wi-Fi 开关重新获取
  --install-desktop     在当前用户桌面生成可双击的 fix_net.command 与 diagnose_net.command
  --install-startup     加入系统开机启动（LaunchDaemon）
  --remove-startup      移除开机启动项（也兼容 /remove-startup）
  --no-startup-prompt   修复完成后不询问是否加入开机启动
  --pause               执行结束后暂停（双击 .command 时默认开启）
  -h, --help            显示此帮助信息
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --status)
                ACTION="status"
                ;;
            --diagnose)
                ACTION="diagnose"
                ;;
            --save)
                shift
                if [[ $# -eq 0 ]]; then
                    echo "[失败] --save 需要指定输出文件路径" >&2
                    exit 2
                fi
                SAVE_PATH="$1"
                ;;
            --dry-run)
                ACTION="dry-run"
                ;;
            --install-desktop)
                ACTION="install-desktop"
                ;;
            --install-startup)
                ACTION="install-startup"
                ;;
            --remove-startup|/remove-startup)
                ACTION="remove-startup"
                ;;
            --startup)
                STARTUP_RUN=1
                NO_STARTUP_PROMPT=1
                ;;
            --service)
                shift
                if [[ $# -eq 0 ]]; then
                    echo "[失败] --service 需要指定网络服务名称" >&2
                    exit 2
                fi
                TARGET_SERVICE="$1"
                ;;
            --device)
                shift
                if [[ $# -eq 0 ]]; then
                    echo "[失败] --device 需要指定网卡设备名（如 en0）" >&2
                    exit 2
                fi
                TARGET_DEVICE="$1"
                ;;
            --reset-dns)
                RESET_DNS=1
                ;;
            --hard)
                HARD_DHCP=1
                ;;
            --no-startup-prompt)
                NO_STARTUP_PROMPT=1
                ;;
            --pause)
                PAUSE_ON_EXIT=1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "[失败] 未知参数：$1" >&2
                usage >&2
                exit 2
                ;;
        esac
        shift
    done
}

resolve_real_user_home() {
    local real_user home_dir
    real_user="${SUDO_USER:-$(id -un 2>/dev/null || echo root)}"
    home_dir=""
    if command -v dscl >/dev/null 2>&1; then
        home_dir="$(dscl . -read "/Users/$real_user" NFSHomeDirectory 2>/dev/null | awk '{print $2}' | head -n 1)"
    fi
    if [[ -z "$home_dir" ]]; then
        home_dir="$HOME"
    fi
    printf '%s\n' "$home_dir"
}

finish_pause() {
    local code="${1:-0}"
    if [[ "$PAUSE_ON_EXIT" -eq 1 && -t 0 && -t 1 ]]; then
        echo ""
        if [[ "$code" -eq 0 && "$ACTION" != "diagnose" && "$ACTION" != "status" ]]; then
            sleep 3
        else
            printf '按回车键关闭窗口...'
            read -r _
        fi
    fi
}

ensure_os() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        echo "[失败] 此脚本仅适用于 macOS。Windows 请使用 scripts/fix_net.bat。" >&2
        exit 1
    fi
}

shell_quote() {
    local out="" arg escaped
    for arg in "$@"; do
        escaped="$(printf '%s' "$arg" | sed "s/'/'\\\\''/g")"
        out="$out '$escaped'"
    done
    printf '%s' "${out# }"
}

ensure_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        return 0
    fi
    if [[ "$STARTUP_RUN" -eq 1 ]]; then
        echo "[失败] 开机启动模式需要 root 权限。" >&2
        exit 1
    fi
    if [[ -t 0 && -t 1 ]]; then
        echo "正在请求管理员权限（请输入开机密码或使用触控 ID）..."
        if [[ ${#ORIG_ARGS[@]} -gt 0 ]]; then
            sudo -- bash "$SELF_PATH" "${ORIG_ARGS[@]}"
        else
            sudo -- bash "$SELF_PATH"
        fi
        local rc=$?
        if [[ "$rc" -ne 0 ]]; then
            echo "[失败] 未取得管理员权限，脚本未执行。" >&2
            finish_pause "$rc"
        fi
        exit "$rc"
    fi

    if command -v osascript >/dev/null 2>&1; then
        local cmd
        if [[ ${#ORIG_ARGS[@]} -gt 0 ]]; then
            cmd="$(shell_quote bash "$SELF_PATH" "${ORIG_ARGS[@]}")"
        else
            cmd="$(shell_quote bash "$SELF_PATH")"
        fi
        local osa_cmd="${cmd//\\/\\\\}"
        osa_cmd="${osa_cmd//\"/\\\"}"
        osascript -e "do shell script \"$osa_cmd\" with administrator privileges"
        exit $?
    fi

    echo "[失败] 请使用 sudo 运行此脚本：sudo bash \"$SELF_PATH\"" >&2
    exit 1
}

# List enabled network services from networksetup, skipping disabled (*) lines.
load_enabled_services() {
    ENABLED_SERVICES=()
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" == An\ asterisk* ]] && continue
        [[ "$line" == \** ]] && continue
        ENABLED_SERVICES+=("$line")
    done < <(networksetup -listallnetworkservices 2>/dev/null || true)
}

# Parse `networksetup -listnetworkserviceorder` into lines: "<service>\t<port>\t<device>"
list_service_bindings() {
    networksetup -listnetworkserviceorder 2>/dev/null | awk '
        /^\(\*\)/ { svc = ""; next }
        /^\([0-9]+\) / {
            svc = $0
            sub(/^\([0-9]+\) /, "", svc)
            next
        }
        /^\(Hardware Port: / && svc != "" {
            line = $0
            sub(/^\(Hardware Port: /, "", line)
            sub(/\)$/, "", line)
            # Find the last ", Device: " in case Hardware Port contains text
            pos = 0
            rest = line
            offset = 0
            while ((idx = index(rest, ", Device: ")) > 0) {
                pos = offset + idx
                offset += idx + 9
                rest = substr(line, offset + 1)
            }
            if (pos > 0) {
                port = substr(line, 1, pos - 1)
                dev = substr(line, pos + 10)
                print svc "\t" port "\t" dev
            }
            svc = ""
        }
    '
}

detect_target_interface() {
    local bindings svc port dev
    bindings="$(list_service_bindings)"
    TARGET_PORT=""

    if [[ -n "$TARGET_SERVICE" ]]; then
        while IFS=$'\t' read -r svc port dev; do
            if [[ "$svc" == "$TARGET_SERVICE" ]]; then
                TARGET_PORT="$port"
                if [[ -z "$TARGET_DEVICE" ]]; then
                    TARGET_DEVICE="$dev"
                fi
                break
            fi
        done <<< "$bindings"
        return 0
    fi

    if [[ -n "$TARGET_DEVICE" ]]; then
        while IFS=$'\t' read -r svc port dev; do
            if [[ "$dev" == "$TARGET_DEVICE" ]]; then
                TARGET_SERVICE="$svc"
                TARGET_PORT="$port"
                break
            fi
        done <<< "$bindings"
        return 0
    fi

    # Priority 1: Wi-Fi / AirPort / WLAN service on physical en* interface
    while IFS=$'\t' read -r svc port dev; do
        local port_lc svc_lc
        port_lc="$(printf '%s' "$port" | tr '[:upper:]' '[:lower:]')"
        svc_lc="$(printf '%s' "$svc" | tr '[:upper:]' '[:lower:]')"
        if [[ "$dev" == en* ]] && {
            [[ "$port_lc" == *wi-fi* || "$port_lc" == *airport* || "$port_lc" == *wlan* || "$port" == *无线局域网* ]] ||
            [[ "$svc_lc" == *wi-fi* || "$svc_lc" == *airport* || "$svc_lc" == *wlan* || "$svc" == *无线局域网* ]];
        }; then
            TARGET_SERVICE="$svc"
            TARGET_PORT="$port"
            TARGET_DEVICE="$dev"
            return 0
        fi
    done <<< "$bindings"

    # Priority 2: Default route interface (ignoring virtual utun* tunnels)
    local default_dev
    default_dev="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
    if [[ -n "$default_dev" && "$default_dev" != utun* ]]; then
        while IFS=$'\t' read -r svc port dev; do
            if [[ "$dev" == "$default_dev" ]]; then
                TARGET_SERVICE="$svc"
                TARGET_PORT="$port"
                TARGET_DEVICE="$dev"
                return 0
            fi
        done <<< "$bindings"
    fi

    # Priority 3: First active en* interface, then first en* interface
    while IFS=$'\t' read -r svc port dev; do
        if [[ "$dev" == en* ]] && is_device_active "$dev"; then
            TARGET_SERVICE="$svc"
            TARGET_PORT="$port"
            TARGET_DEVICE="$dev"
            return 0
        fi
    done <<< "$bindings"

    while IFS=$'\t' read -r svc port dev; do
        if [[ "$dev" == en* ]]; then
            TARGET_SERVICE="$svc"
            TARGET_PORT="$port"
            TARGET_DEVICE="$dev"
            return 0
        fi
    done <<< "$bindings"
}

is_device_active() {
    local dev="$1"
    [[ -n "$dev" ]] || return 1
    ifconfig "$dev" 2>/dev/null | grep -q 'status: active'
}

is_wifi_hardware() {
    local port_lc
    port_lc="$(printf '%s' "${TARGET_PORT:-$TARGET_SERVICE}" | tr '[:upper:]' '[:lower:]')"
    [[ "$port_lc" == *wi-fi* || "$port_lc" == *airport* || "$port_lc" == *wlan* || "${TARGET_PORT:-}" == *无线局域网* ]]
}

join_lines() {
    awk 'NF { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); out = (out == "" ? $0 : out " " $0) } END { printf "%s", out }'
}

read_proxy_field() {
    local key="$1"
    sed -n "s/^${key}: //p" | head -n 1
}

disable_proxies_for_service() {
    local svc="$1" is_primary="$2"
    local kind failed=0

    for kind in webproxy securewebproxy socksfirewallproxy; do
        if ! networksetup "-set${kind}state" "$svc" off >/dev/null 2>&1; then
            failed=1
        fi
    done

    if ! networksetup -setproxyautodiscovery "$svc" off >/dev/null 2>&1; then
        failed=1
    fi
    if ! networksetup -setautoproxystate "$svc" off >/dev/null 2>&1; then
        failed=1
    fi

    if [[ "$is_primary" -eq 1 && "$failed" -ne 0 ]]; then
        return 1
    fi
    return 0
}

clear_proxies_for_service() {
    local svc="$1"
    local kind out server port pac_url

    for kind in webproxy securewebproxy socksfirewallproxy; do
        out="$(networksetup "-get${kind}" "$svc" 2>/dev/null || true)"
        server="$(printf '%s\n' "$out" | read_proxy_field "Server")"
        port="$(printf '%s\n' "$out" | read_proxy_field "Port")"
        if [[ -n "$server" || ( -n "$port" && "$port" != "0" ) ]]; then
            # -set*proxy turns the toggle on, so always re-apply state off immediately.
            networksetup "-set${kind}" "$svc" "" 0 >/dev/null 2>&1 || true
            networksetup "-set${kind}state" "$svc" off >/dev/null 2>&1 || true
        fi
    done

    out="$(networksetup -getautoproxyurl "$svc" 2>/dev/null || true)"
    pac_url="$(printf '%s\n' "$out" | read_proxy_field "URL")"
    if [[ -n "$pac_url" && "$pac_url" != "(null)" ]]; then
        networksetup -setautoproxyurl "$svc" "" >/dev/null 2>&1 || true
        networksetup -setautoproxystate "$svc" off >/dev/null 2>&1 || true
    fi
}

verify_service_proxies_off() {
    local svc="$1"
    local kind enabled autodisc

    for kind in webproxy securewebproxy socksfirewallproxy; do
        enabled="$(networksetup "-get${kind}" "$svc" 2>/dev/null | read_proxy_field "Enabled")"
        if [[ "$enabled" == "Yes" ]]; then
            return 1
        fi
    done

    enabled="$(networksetup -getautoproxyurl "$svc" 2>/dev/null | read_proxy_field "Enabled")"
    if [[ "$enabled" == "Yes" ]]; then
        return 1
    fi

    autodisc="$(networksetup -getproxyautodiscovery "$svc" 2>/dev/null | read_proxy_field "Auto Proxy Discovery")"
    if [[ "$autodisc" == "On" ]]; then
        return 1
    fi

    return 0
}

step_disable_proxies() {
    echo "[1/6] 关闭 macOS 系统代理..."
    local svc primary_flag step_failed=0

    if [[ ${#ENABLED_SERVICES[@]} -eq 0 ]]; then
        echo "[失败] 未找到已启用的网络服务"
        RESULT=1
        return
    fi

    for svc in "${ENABLED_SERVICES[@]}"; do
        primary_flag=0
        [[ "$svc" == "$TARGET_SERVICE" ]] && primary_flag=1
        if ! disable_proxies_for_service "$svc" "$primary_flag"; then
            step_failed=1
        fi
    done

    if [[ "$step_failed" -ne 0 ]]; then
        echo "[失败] 无法关闭 ${TARGET_SERVICE} 的系统代理"
        RESULT=1
    else
        echo "[完成] 系统代理已关闭（已覆盖 ${#ENABLED_SERVICES[@]} 个启用服务）"
    fi
}

step_clear_proxies() {
    echo "[2/6] 清理代理地址、端口和 PAC..."
    local svc
    for svc in "${ENABLED_SERVICES[@]}"; do
        clear_proxies_for_service "$svc"
    done

    if [[ -n "$TARGET_SERVICE" ]] && ! verify_service_proxies_off "$TARGET_SERVICE"; then
        echo "[失败] ${TARGET_SERVICE} 代理状态未成功关闭"
        RESULT=1
    else
        echo "[完成] 代理地址和 PAC 已清理"
    fi
}

step_flush_dns() {
    echo "[3/6] 刷新 DNS 缓存..."
    local dns_failed=0

    if ! dscacheutil -flushcache >/dev/null 2>&1; then
        dns_failed=1
    fi
    if ! killall -HUP mDNSResponder >/dev/null 2>&1; then
        dns_failed=1
    fi

    if [[ "$dns_failed" -ne 0 ]]; then
        echo "[失败] DNS 缓存刷新失败"
        RESULT=1
    else
        echo "[完成] DNS 缓存已刷新"
    fi

    if [[ -n "$TARGET_SERVICE" ]]; then
        local manual_dns
        manual_dns="$(networksetup -getdnsservers "$TARGET_SERVICE" 2>/dev/null || true)"
        if [[ -n "$manual_dns" && "$manual_dns" != There\ aren\'t\ any\ DNS\ Servers* ]]; then
            local dns_one_line
            dns_one_line="$(printf '%s\n' "$manual_dns" | join_lines)"
            if [[ "$RESET_DNS" -eq 1 ]]; then
                if networksetup -setdnsservers "$TARGET_SERVICE" Empty >/dev/null 2>&1; then
                    echo "[完成] 已清除手动 DNS（${dns_one_line}），恢复为 DHCP 自动获取"
                else
                    echo "[失败] 无法清除手动 DNS 设置"
                    RESULT=1
                fi
            else
                echo "[提示] ${TARGET_SERVICE} 当前设置了手动 DNS（${dns_one_line}）；若认证页仍打不开，可加 --reset-dns 恢复为自动 DNS"
            fi
        fi
    fi
}

step_clear_arp() {
    echo "[4/6] 清理 ARP 缓存..."
    if [[ -n "$TARGET_DEVICE" ]]; then
        arp -d -i "$TARGET_DEVICE" -a >/dev/null 2>&1 || true
    else
        arp -d -a >/dev/null 2>&1 || true
    fi

    local remaining
    if [[ -n "$TARGET_DEVICE" ]]; then
        remaining="$(arp -an -i "$TARGET_DEVICE" 2>/dev/null | grep -v 'permanent' || true)"
    else
        remaining="$(arp -an 2>/dev/null | grep -v 'permanent' || true)"
    fi

    if [[ -z "$remaining" ]]; then
        echo "[完成] ARP 缓存已清理"
    else
        echo "[提示] ARP 缓存清理未完成（仍有动态条目或系统拒绝删除）"
    fi
}

bounce_interface() {
    local dev="$1"
    if is_wifi_hardware; then
        networksetup -setairportpower "$dev" off >/dev/null 2>&1 || return 1
        sleep 2
        networksetup -setairportpower "$dev" on >/dev/null 2>&1 || return 1
    else
        ifconfig "$dev" down >/dev/null 2>&1 || return 1
        sleep 2
        ifconfig "$dev" up >/dev/null 2>&1 || return 1
    fi
}

step_prepare_and_renew_dhcp() {
    echo "[5/6] 确认 ${TARGET_SERVICE} (${TARGET_DEVICE}) 的 DHCP 配置并触发续租..."

    if [[ -z "$TARGET_SERVICE" || -z "$TARGET_DEVICE" ]]; then
        echo "[失败] 未找到可用的网络服务或网卡接口"
        RESULT=1
        return
    fi

    local info_out
    info_out="$(networksetup -getinfo "$TARGET_SERVICE" 2>/dev/null || true)"
    if [[ "$info_out" != DHCP\ Configuration* ]]; then
        if ! networksetup -setdhcp "$TARGET_SERVICE" >/dev/null 2>&1; then
            echo "[失败] 无法将 ${TARGET_SERVICE} 切换为 DHCP 模式"
            RESULT=1
            return
        fi
        echo "[完成] 已将 ${TARGET_SERVICE} 设为 DHCP 自动获取"
    fi

    if is_wifi_hardware; then
        local power_out
        power_out="$(networksetup -getairportpower "$TARGET_DEVICE" 2>/dev/null || true)"
        if [[ "$power_out" == *": Off"* ]]; then
            if [[ "$STARTUP_RUN" -eq 1 ]]; then
                echo "[跳过] 开机启动时 Wi-Fi 处于关闭状态，跳过 DHCP 续租"
                return
            fi
            echo "[提示] 检测到 Wi-Fi 电源关闭，正在开启..."
            networksetup -setairportpower "$TARGET_DEVICE" on >/dev/null 2>&1 || true
            sleep 3
        fi
    fi

    if ! is_device_active "$TARGET_DEVICE"; then
        if [[ "$STARTUP_RUN" -eq 1 ]]; then
            echo "[跳过] 开机启动时 ${TARGET_DEVICE} 尚未连接，跳过 DHCP 续租"
            return
        fi
        echo "[提示] ${TARGET_DEVICE} 当前链路未激活（status 非 active），仍尝试刷新配置..."
    fi

    if [[ "$HARD_DHCP" -eq 1 ]]; then
        if bounce_interface "$TARGET_DEVICE"; then
            echo "[完成] 已重启 ${TARGET_DEVICE} 接口并重新触发 DHCP"
        else
            echo "[失败] 重启 ${TARGET_DEVICE} 接口失败"
            RESULT=1
        fi
        return
    fi

    if scutil --renew "$TARGET_DEVICE" >/dev/null 2>&1; then
        echo "[完成] 已触发 ${TARGET_DEVICE} DHCP 续租请求"
    else
        echo "[失败] DHCP 续租请求失败 (scutil --renew $TARGET_DEVICE)"
        RESULT=1
    fi
}

is_valid_dhcp_ip() {
    local ip="$1"
    [[ -n "$ip" && "$ip" != 169.254.* ]]
}

step_verify_dhcp_lease() {
    echo "[6/6] 等待并校验 ${TARGET_DEVICE} 的 DHCP 租约..."

    if [[ -z "$TARGET_DEVICE" ]]; then
        echo "[失败] 无有效网卡接口可校验"
        RESULT=1
        return
    fi

    if [[ "$STARTUP_RUN" -eq 1 ]] && ! is_device_active "$TARGET_DEVICE"; then
        echo "[跳过] ${TARGET_DEVICE} 尚未连接，连接校园 Wi-Fi 后将自动获取租约"
        return
    fi

    local i=0 ip="" summary=""
    while [[ "$i" -lt "$DHCP_WAIT_SECONDS" ]]; do
        ip="$(ipconfig getifaddr "$TARGET_DEVICE" 2>/dev/null || true)"
        summary="$(ipconfig getsummary "$TARGET_DEVICE" 2>/dev/null || true)"
        if is_valid_dhcp_ip "$ip" && printf '%s\n' "$summary" | grep -q 'State : BOUND'; then
            break
        fi
        sleep 1
        i=$((i + 1))
    done

    ip="$(ipconfig getifaddr "$TARGET_DEVICE" 2>/dev/null || true)"
    local router dhcp_dns
    router="$(ipconfig getoption "$TARGET_DEVICE" router 2>/dev/null || true)"
    dhcp_dns="$(ipconfig getoption "$TARGET_DEVICE" domain_name_server 2>/dev/null | join_lines || true)"

    if is_valid_dhcp_ip "$ip"; then
        echo "[完成] DHCP 租约正常：IP=${ip}，网关=${router:-未知}，DHCP DNS=${dhcp_dns:-无}"
    else
        echo "[失败] 未获取到有效 DHCP 地址（当前：${ip:-无}）"
        if [[ "$HARD_DHCP" -eq 0 ]]; then
            echo "[提示] 如卡在无 IP 或 169.254.x.x，可尝试加 --hard 参数重启接口重连"
        fi
        RESULT=1
    fi
}

print_extra_hints() {
    local default_if captive_ip probe_target probe_if tun_if=""
    default_if="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
    captive_ip="$(dscacheutil -q host -a name captive.apple.com 2>/dev/null | awk '/^ip_address:/{print $2; exit}')"
    probe_target="${captive_ip:-8.8.8.8}"
    probe_if="$(route -n get "$probe_target" 2>/dev/null | awk '/interface:/{print $2; exit}')"

    if [[ "$default_if" == utun* ]]; then
        tun_if="$default_if"
    elif [[ "$probe_if" == utun* ]]; then
        tun_if="$probe_if"
    fi

    if [[ -n "$tun_if" ]]; then
        echo "[提示] 检测到公网流量经过虚拟网卡 (${tun_if})（常见于 Clash TUN / VPN 分流接管），系统可能无法弹出校园网登录页；请先关闭 TUN 或 VPN 后重试"
    fi

    if [[ "$captive_ip" == 28.0.* || "$captive_ip" == 198.18.* || "$captive_ip" == 198.19.* ]]; then
        echo "[提示] 检测到 captive.apple.com 被解析为 Fake-IP (${captive_ip})，这会直接阻止 macOS 弹出校园网认证窗口；请先关闭代理软件的 TUN / Fake-IP"
    fi

    if command -v pgrep >/dev/null 2>&1; then
        local running_proxy="" proc
        for proc in clash-verge verge-mihomo mihomo; do
            if pgrep -x "$proc" >/dev/null 2>&1; then
                running_proxy="${running_proxy:+$running_proxy, }$proc"
            fi
        done
        if [[ -n "$running_proxy" ]]; then
            echo "[提示] 检测到后台仍在运行代理进程 (${running_proxy})；macOS 点窗口红叉不会退出，服务模式也可能保留内核，请在菜单栏托盘中先关闭 TUN 与系统代理后再选“退出”"
        fi
    fi

    if [[ -n "${http_proxy:-}${https_proxy:-}${all_proxy:-}${HTTP_PROXY:-}${HTTPS_PROXY:-}${ALL_PROXY:-}" ]]; then
        echo "[提示] 检测到当前终端存在代理环境变量；若终端请求仍走代理，请先执行 unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY"
    fi
}

render_launchd_plist() {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${INSTALLED_SCRIPT}</string>
        <string>--startup</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>
</dict>
</plist>
EOF
}

install_startup() {
    mkdir -p "$SUPPORT_DIR" "$LAUNCH_DAEMONS_DIR" "$(dirname "$LOG_FILE")"
    cp "$SELF_PATH" "$INSTALLED_SCRIPT"
    chmod 755 "$INSTALLED_SCRIPT"
    chown root:wheel "$INSTALLED_SCRIPT" 2>/dev/null || true

    render_launchd_plist > "$DAEMON_PLIST"
    chmod 644 "$DAEMON_PLIST"
    chown root:wheel "$DAEMON_PLIST" 2>/dev/null || true

    launchctl enable "system/$LABEL" >/dev/null 2>&1 || true
    echo "[完成] 已加入系统开机启动：$DAEMON_PLIST"
}

remove_startup() {
    local removed=0 real_home agent_plist
    real_home="$(resolve_real_user_home)"
    agent_plist="${LAUNCH_AGENTS_DIR:-$real_home/Library/LaunchAgents}/$LABEL.plist"

    if [[ -f "$DAEMON_PLIST" || -d "$SUPPORT_DIR" ]]; then
        launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
        rm -f "$DAEMON_PLIST"
        rm -rf "$SUPPORT_DIR"
        echo "已移除开机启动：$DAEMON_PLIST"
        removed=1
    fi

    if [[ -f "$agent_plist" ]]; then
        rm -f "$agent_plist"
        echo "已移除用户启动项：$agent_plist"
        removed=1
    fi

    if [[ "$removed" -eq 0 ]]; then
        echo "未找到开机启动项。"
    fi
}

install_desktop() {
    local real_home real_user desktop_fix desktop_diag
    real_home="$(resolve_real_user_home)"
    real_user="${SUDO_USER:-$(id -un 2>/dev/null || true)}"
    desktop_fix="$real_home/Desktop/fix_net.command"
    desktop_diag="$real_home/Desktop/diagnose_net.command"

    mkdir -p "$real_home/Desktop"
    cp "$SELF_PATH" "$desktop_fix"
    chmod 755 "$desktop_fix"
    xattr -d com.apple.quarantine "$desktop_fix" >/dev/null 2>&1 || true

    cat > "$desktop_diag" <<'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$SCRIPT_DIR/fix_net.command" --diagnose --pause "$@"
EOF
    chmod 755 "$desktop_diag"
    xattr -d com.apple.quarantine "$desktop_diag" >/dev/null 2>&1 || true

    if [[ "$(id -u)" -eq 0 && -n "$real_user" ]]; then
        chown "$real_user" "$desktop_fix" "$desktop_diag" 2>/dev/null || true
    fi
    echo "[完成] 已生成桌面可执行文件："
    echo "  修复工具：$desktop_fix"
    echo "  断网检测：$desktop_diag"
}

prompt_startup_if_needed() {
    if [[ "$STARTUP_RUN" -eq 1 || "$NO_STARTUP_PROMPT" -eq 1 || -f "$DAEMON_PLIST" ]]; then
        return 0
    fi
    if [[ ! -t 0 || ! -t 1 ]]; then
        return 0
    fi

    echo ""
    printf '是否加入系统开机启动（LaunchDaemon）？[y/N]：'
    local ans
    read -r ans
    case "$ans" in
        y|Y|yes|YES)
            if ! install_startup; then
                echo "[失败] 加入开机启动失败"
                RESULT=1
            fi
            ;;
        *)
            ;;
    esac
}

print_status() {
    load_enabled_services
    detect_target_interface

    echo "=========================================="
    echo "  macOS 校园网状态检查（只读）"
    echo "=========================================="
    echo "目标服务：${TARGET_SERVICE:-未找到}"
    echo "网卡接口：${TARGET_DEVICE:-未找到}"
    echo "硬件类型：${TARGET_PORT:-未知}"
    echo "启用服务数：${#ENABLED_SERVICES[@]}"
    echo ""

    if [[ -n "$TARGET_DEVICE" ]]; then
        local active="否"
        is_device_active "$TARGET_DEVICE" && active="是"
        echo "链路状态 active：$active"
        echo "IPv4 地址：$(ipconfig getifaddr "$TARGET_DEVICE" 2>/dev/null || echo '无')"
        echo "DHCP 网关：$(ipconfig getoption "$TARGET_DEVICE" router 2>/dev/null || echo '无')"
    fi

    if [[ -n "$TARGET_SERVICE" ]]; then
        echo ""
        echo "--- ${TARGET_SERVICE} DNS ---"
        networksetup -getdnsservers "$TARGET_SERVICE" 2>/dev/null || true
        echo ""
        echo "--- ${TARGET_SERVICE} 代理状态 ---"
        networksetup -getwebproxy "$TARGET_SERVICE" 2>/dev/null || true
        networksetup -getsecurewebproxy "$TARGET_SERVICE" 2>/dev/null || true
        networksetup -getsocksfirewallproxy "$TARGET_SERVICE" 2>/dev/null || true
        networksetup -getautoproxyurl "$TARGET_SERVICE" 2>/dev/null || true
        networksetup -getproxyautodiscovery "$TARGET_SERVICE" 2>/dev/null || true
    fi

    echo ""
    if [[ -f "$DAEMON_PLIST" ]]; then
        echo "开机启动：已安装 ($DAEMON_PLIST)"
    else
        echo "开机启动：未安装"
    fi
    print_extra_hints
}

print_diagnose() {
    load_enabled_services
    detect_target_interface

    local issues=()
    local ip="" router="" dhcp_dns="" manual_dns="" active="否"
    local captive_sys_ip="" probe_if="" default_if="" running_proxy="" proc=""

    echo "=========================================="
    echo "  macOS 校园网断网深度检测（只读 / 免密码）"
    echo "  时间：$(date '+%Y-%m-%d %H:%M:%S')"
    echo "=========================================="
    echo ""

    # L1: Interface & DHCP
    echo "【L1 网卡与 DHCP】"
    echo "  目标服务：${TARGET_SERVICE:-未找到} | 接口：${TARGET_DEVICE:-未找到} | 类型：${TARGET_PORT:-未知}"
    if [[ -n "$TARGET_DEVICE" ]]; then
        is_device_active "$TARGET_DEVICE" && active="是"
        ip="$(ipconfig getifaddr "$TARGET_DEVICE" 2>/dev/null || true)"
        router="$(ipconfig getoption "$TARGET_DEVICE" router 2>/dev/null || true)"
        dhcp_dns="$(ipconfig getoption "$TARGET_DEVICE" domain_name_server 2>/dev/null | join_lines || true)"
        echo "  链路 active：$active"
        echo "  IPv4 地址：${ip:-无} | 网关：${router:-无}"
        echo "  DHCP 下发 DNS：${dhcp_dns:-无}"
        if [[ "$active" != "是" ]]; then
            issues+=("Wi-Fi 接口 ${TARGET_DEVICE} 未连接（status 非 active）")
        elif [[ -z "$ip" || "$ip" == 169.254.* ]]; then
            issues+=("未拿到有效 DHCP 地址（当前：${ip:-无}），建议运行 fix_net.sh --hard")
        fi
    else
        issues+=("未检测到可用物理网卡接口")
    fi

    local utuns
    utuns="$(ifconfig 2>/dev/null | awk '/^utun[0-9]+:/{dev=$1; sub(/:$/,"",dev)} /^[[:space:]]+inet /{if(dev!=""){ out = (out=="" ? dev " -> " $2 : out "; " dev " -> " $2); dev="" }} END{printf "%s", out}')"
    echo "  带 IPv4 的虚拟网卡：${utuns:-无}"

    # L2: Proxy & Routing
    echo ""
    echo "【L2 代理软件与路由劫持】"
    if [[ -n "$TARGET_SERVICE" ]]; then
        local kind out en srv port pac
        for kind in webproxy securewebproxy socksfirewallproxy; do
            out="$(networksetup "-get${kind}" "$TARGET_SERVICE" 2>/dev/null || true)"
            en="$(printf '%s\n' "$out" | read_proxy_field "Enabled")"
            srv="$(printf '%s\n' "$out" | read_proxy_field "Server")"
            port="$(printf '%s\n' "$out" | read_proxy_field "Port")"
            echo "  ${kind}: Enabled=${en:-未知} ${srv:+($srv:$port)}"
            if [[ "$en" == "Yes" ]]; then
                issues+=("系统代理 ${kind} 仍开启 (${srv}:${port})，建议运行 fix_net.sh 关闭")
            fi
        done
        pac="$(networksetup -getautoproxyurl "$TARGET_SERVICE" 2>/dev/null | join_lines || true)"
        echo "  autoproxy: ${pac:-无}"
        if [[ "$pac" == *"Enabled: Yes"* ]]; then
            issues+=("系统 PAC 自动代理仍开启")
        fi
    fi

    if command -v pgrep >/dev/null 2>&1; then
        for proc in clash-verge verge-mihomo mihomo; do
            if pgrep -x "$proc" >/dev/null 2>&1; then
                running_proxy="${running_proxy:+$running_proxy, }$proc"
            fi
        done
    fi
    echo "  后台代理进程：${running_proxy:-未发现}"
    if [[ -n "$running_proxy" ]]; then
        issues+=("后台仍在运行代理进程 (${running_proxy})，点窗口红叉未真退出或服务模式残留")
    fi

    default_if="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
    captive_sys_ip="$(dscacheutil -q host -a name captive.apple.com 2>/dev/null | awk '/^ip_address:/{print $2; exit}')"
    probe_if="$(route -n get "${captive_sys_ip:-8.8.8.8}" 2>/dev/null | awk '/interface:/{print $2; exit}')"
    echo "  默认路由接口：${default_if:-无} | 探测路由(${captive_sys_ip:-8.8.8.8})接口：${probe_if:-无}"
    if [[ "$default_if" == utun* || "$probe_if" == utun* ]]; then
        issues+=("公网探测流量正经过虚拟网卡 (${probe_if:-$default_if})，会拦截校园网认证跳转")
    fi

    # L3: DNS
    echo ""
    echo "【L3 DNS 解析对比】"
    if [[ -n "$TARGET_SERVICE" ]]; then
        manual_dns="$(networksetup -getdnsservers "$TARGET_SERVICE" 2>/dev/null | join_lines || true)"
    fi
    echo "  当前手动 DNS 配置：${manual_dns:-未知}"
    echo "  系统解析 captive.apple.com：${captive_sys_ip:-失败}"
    if [[ "$captive_sys_ip" == 28.0.* || "$captive_sys_ip" == 198.18.* || "$captive_sys_ip" == 198.19.* ]]; then
        issues+=("captive.apple.com 被 Fake-IP (${captive_sys_ip}) 劫持，无法触发认证弹窗")
    elif [[ -z "$captive_sys_ip" ]]; then
        issues+=("系统无法解析 captive.apple.com")
    fi

    if [[ -n "$manual_dns" && "$manual_dns" != There\ aren\'t\ any\ DNS\ Servers* ]]; then
        echo "  [对比] 已设置手动 DNS (${manual_dns})"
        if [[ -n "$dhcp_dns" ]] && command -v dig >/dev/null 2>&1; then
            local first_dhcp_dns dhcp_ans
            first_dhcp_dns="${dhcp_dns%% *}"
            dhcp_ans="$(dig +short +time=2 +tries=1 @"$first_dhcp_dns" captive.apple.com 2>/dev/null | join_lines || true)"
            echo "  [对比] 改问 DHCP DNS (${first_dhcp_dns}) 解析结果：${dhcp_ans:-失败}"
            if [[ -z "$captive_sys_ip" && -n "$dhcp_ans" ]]; then
                issues+=("手动 DNS (${manual_dns}) 被校园网拦截而 DHCP DNS (${first_dhcp_dns}) 可解析，请运行 fix_net.sh --reset-dns")
            fi
        fi
        issues+=("当前挂着手动 DNS (${manual_dns})，未认证校园网时可能阻断域名解析，可尝试 --reset-dns")
    fi

    # L4: Gateway & Captive HTTP Probe
    echo ""
    echo "【L4 网关连通与直连 HTTP 探针】"
    if [[ -n "$router" ]]; then
        local gw_ok="失败"
        if ping -c 1 -W 1000 "$router" >/dev/null 2>&1 || nc -z -G 2 "$router" 80 >/dev/null 2>&1 || nc -z -G 2 "$router" 443 >/dev/null 2>&1; then
            gw_ok="可达"
        else
            issues+=("连校园网网关 ${router} 都不可达（Wi-Fi 假连接或 AP 丢包）")
        fi
        echo "  网关 (${router}) 可达性：$gw_ok"
    fi

    if command -v curl >/dev/null 2>&1; then
        local hdr_file body_file http_code curl_err="" location="" body_preview="" portal_code=""
        hdr_file="$(mktemp)"
        body_file="$(mktemp)"
        http_code="$(curl -4 -sS -D "$hdr_file" -o "$body_file" -w '%{http_code}' --noproxy '*' --connect-timeout 4 --max-time 6 http://captive.apple.com/hotspot-detect.html 2>"$hdr_file.err")" || curl_err="$(cat "$hdr_file.err" 2>/dev/null || true)"
        echo "  直连 captive.apple.com 状态码：${http_code:-000} ${curl_err:+($curl_err)}"

        if [[ "$http_code" == "200" ]] && grep -q "Success" "$body_file" 2>/dev/null; then
            echo "  探测结果：已正常联网（返回 Success，当前网络无需认证）"
        elif [[ "$http_code" == "301" || "$http_code" == "302" || "$http_code" == "303" || "$http_code" == "307" || "$http_code" == "308" ]]; then
            location="$(awk 'tolower($1)=="location:"{sub(/\r$/,"",$2); print $2; exit}' "$hdr_file" 2>/dev/null || true)"
            echo "  捕获跳转认证地址：${location:-未知}"
            if [[ -n "$location" ]]; then
                portal_code="$(curl -4 -sS -o /dev/null -w '%{http_code}' --noproxy '*' --connect-timeout 4 --max-time 6 "$location" 2>"$hdr_file.perr" || true)"
                if [[ "$portal_code" == "200" || "$portal_code" == "302" ]]; then
                    echo "  认证页可达性：HTTP ${portal_code}（可直接在浏览器打开上面地址登录）"
                    issues+=("网关已下发跳转页 (${location}) 且页面可访问；若系统未弹窗，直接浏览器打开该地址即可")
                else
                    echo "  认证页可达性：超时/异常 (HTTP ${portal_code:-000} $(cat "$hdr_file.perr" 2>/dev/null || true))"
                    issues+=("网关已 302 跳转到 ${location}，但认证服务器响应超时/卡死，导致系统误判或白屏")
                fi
            fi
        elif [[ "$http_code" == "200" ]]; then
            body_preview="$(tr '\r\n' ' ' < "$body_file" 2>/dev/null | head -c 160)"
            echo "  捕获非 Success 的 200 页面（可能为 JS 跳转页）：${body_preview}"
            issues+=("网关返回了认证劫持页（非标准 302），可打开 http://captive.apple.com 或网关 ${router:-} 登录")
        else
            issues+=("直连 http://captive.apple.com 失败 (${http_code:-000} ${curl_err})")
        fi
        rm -f "$hdr_file" "$hdr_file.err" "$hdr_file.perr" "$body_file"
    fi

    # L5: Last 15m Apple Captive / DHCP system logs
    echo ""
    echo "【L5 最近 15 分钟系统认证裁决日志】"
    if command -v log >/dev/null 2>&1; then
        local log_lines log_dev
        log_dev="${TARGET_DEVICE:-en0}"
        log_lines="$(log show --last 15m --style compact --predicate "subsystem == \"com.apple.captive\" OR subsystem == \"com.apple.CaptiveNetworkAssistant\" OR (process == \"captiveagent\" AND messageType == error) OR (process == \"configd\" AND eventMessage CONTAINS \"DHCP ${log_dev}\")" 2>/dev/null | grep -E 'Launching Websheet|Redirect detected|assuming online|Authenticated|timed out|link INACTIVE|error code:|connect_stalled|status 302' | tail -n 12 || true)"
        if [[ -n "$log_lines" ]]; then
            printf '%s\n' "$log_lines" | sed 's/^/  /'
            if printf '%s\n' "$log_lines" | grep -q 'assuming online'; then
                issues+=("系统日志出现 'assuming online'：探测超时导致 macOS 误标为已认证，后续不再自动弹窗（需关闭重连 Wi-Fi 或用浏览器开认证页）")
            fi
            if printf '%s\n' "$log_lines" | grep -q 'connect_stalled'; then
                issues+=("系统日志出现 'connect_stalled'：连认证服务器后超时未吐数据")
            fi
        else
            echo "  （最近 15 分钟内无相关异常/弹窗裁决记录）"
        fi
    fi

    echo ""
    echo "【诊断结论与建议】"
    if [[ ${#issues[@]} -eq 0 ]]; then
        echo "  [正常] 未发现阻塞校园网登录弹窗的异常项。"
    else
        local idx=1 item
        for item in "${issues[@]}"; do
            echo "  ${idx}. ${item}"
            idx=$((idx + 1))
        done
    fi
}

print_dry_run() {
    load_enabled_services
    detect_target_interface

    echo "=========================================="
    echo "  macOS 校园网修复预览（dry-run）"
    echo "=========================================="
    echo "目标服务：${TARGET_SERVICE:-未找到}"
    echo "网卡接口：${TARGET_DEVICE:-未找到}"
    echo "将处理的启用服务：${ENABLED_SERVICES[*]:-无}"
    echo ""
    echo "[1/6] 将关闭所有启用服务的 Web/HTTPS/SOCKS/自动发现/PAC 代理开关"
    echo "[2/6] 将清空残留代理服务器地址、端口及 PAC URL"
    echo "[3/6] 将执行 dscacheutil -flushcache 与 killall -HUP mDNSResponder"
    if [[ "$RESET_DNS" -eq 1 && -n "$TARGET_SERVICE" ]]; then
        echo "      并执行 networksetup -setdnsservers \"$TARGET_SERVICE\" Empty"
    fi
    if [[ -n "$TARGET_DEVICE" ]]; then
        echo "[4/6] 将执行 arp -d -i \"$TARGET_DEVICE\" -a"
        echo "[5/6] 将确认 \"$TARGET_SERVICE\" 为 DHCP 并执行 $( [[ "$HARD_DHCP" -eq 1 ]] && echo '接口重启' || echo "scutil --renew \"$TARGET_DEVICE\"" )"
        echo "[6/6] 将轮询等待 \"$TARGET_DEVICE\" 获取有效 DHCP IP 与网关"
    fi
}

run_readonly_output() {
    local fn="$1"
    if [[ -n "$SAVE_PATH" ]]; then
        mkdir -p "$(dirname "$SAVE_PATH")"
        "$fn" | tee "$SAVE_PATH"
        echo ""
        echo "[已保存检测报告] $SAVE_PATH"
    else
        "$fn"
    fi
}

main() {
    ensure_os
    parse_args "$@"

    case "$ACTION" in
        status)
            run_readonly_output print_status
            finish_pause 0
            exit 0
            ;;
        diagnose)
            run_readonly_output print_diagnose
            finish_pause 0
            exit 0
            ;;
        dry-run)
            print_dry_run
            exit 0
            ;;
        install-desktop)
            install_desktop
            finish_pause 0
            exit 0
            ;;
        install-startup)
            ensure_root
            install_startup
            exit $?
            ;;
        remove-startup)
            ensure_root
            remove_startup
            exit $?
            ;;
    esac

    ensure_root
    load_enabled_services
    detect_target_interface

    echo ""
    echo "=========================================="
    echo "  刷新校园网网络环境 (macOS)"
    echo "  服务：${TARGET_SERVICE:-未知} | 接口：${TARGET_DEVICE:-未知}"
    echo "=========================================="
    echo ""

    step_disable_proxies
    step_clear_proxies
    step_flush_dns
    step_clear_arp
    step_prepare_and_renew_dhcp
    step_verify_dhcp_lease
    print_extra_hints
    prompt_startup_if_needed

    echo ""
    if [[ "$RESULT" -eq 0 ]]; then
        echo "网络刷新完成。"
    else
        echo "网络刷新完成，但有步骤失败，请查看上面的提示。"
    fi

    finish_pause "$RESULT"
    exit "$RESULT"
}

main "$@"
