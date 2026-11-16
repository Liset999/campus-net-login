#!/usr/bin/env bash
# Sandboxed unit & integration tests for scripts/fix_net.sh using mocked macOS tools.

set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$REPO_DIR/scripts/fix_net.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

MOCK_BIN="$TMP_ROOT/bin"
STATE_DIR="$TMP_ROOT/state"
LOG_FILE="$TMP_ROOT/calls.log"
DAEMONS_DIR="$TMP_ROOT/LaunchDaemons"
AGENTS_DIR="$TMP_ROOT/LaunchAgents"
SUPPORT_DIR="$TMP_ROOT/Support"
HOME_DIR="$TMP_ROOT/home"

mkdir -p "$MOCK_BIN" "$STATE_DIR" "$DAEMONS_DIR" "$AGENTS_DIR" "$SUPPORT_DIR" "$HOME_DIR/Desktop"

export CAMPUS_NET_LAUNCH_DAEMONS_DIR="$DAEMONS_DIR"
export CAMPUS_NET_LAUNCH_AGENTS_DIR="$AGENTS_DIR"
export CAMPUS_NET_SUPPORT_DIR="$SUPPORT_DIR"
export CAMPUS_NET_LOG_FILE="$TMP_ROOT/fix.log"
export CAMPUS_NET_DHCP_WAIT_SECONDS="2"
export MOCK_STATE_DIR="$STATE_DIR"
export MOCK_CALL_LOG="$LOG_FILE"
export HOME="$HOME_DIR"
unset SUDO_USER || true

cat > "$MOCK_BIN/id" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-u" ]]; then
    echo "${MOCK_UID:-0}"
elif [[ "$1" == "-un" ]]; then
    echo "tester"
else
    /usr/bin/id "$@"
fi
EOF

cat > "$MOCK_BIN/dscl" <<EOF
#!/usr/bin/env bash
echo "NFSHomeDirectory: $HOME_DIR"
EOF

cat > "$MOCK_BIN/uname" <<'EOF'
#!/usr/bin/env bash
echo "Darwin"
EOF

cat > "$MOCK_BIN/networksetup" <<'EOF'
#!/usr/bin/env bash
echo "networksetup $*" >> "$MOCK_CALL_LOG"
cmd="$1"
shift || true
case "$cmd" in
    -listallnetworkservices)
        cat <<'OUT'
An asterisk (*) denotes that a network service is disabled.
Thunderbolt Bridge
Wi-Fi
*Bluetooth PAN
EnAgent-VPN
OUT
        ;;
    -listnetworkserviceorder)
        cat <<'OUT'
An asterisk (*) denotes that a network service is disabled.
(1) Thunderbolt Bridge
(Hardware Port: Thunderbolt Bridge, Device: bridge0)

(2) Wi-Fi
(Hardware Port: Wi-Fi, Device: en0)

(*) Bluetooth PAN
(Hardware Port: Bluetooth PAN, Device: en5)
OUT
        ;;
    -getwebproxy|-getsecurewebproxy|-getsocksfirewallproxy)
        svc="$1"
        state_file="$MOCK_STATE_DIR/${cmd#-get}_$(printf '%s' "$svc" | tr ' /' '__')"
        if [[ -f "$state_file" ]]; then
            cat "$state_file"
        elif [[ "$svc" == "Wi-Fi" ]]; then
            printf 'Enabled: Yes\nServer: 127.0.0.1\nPort: 7897\nAuthenticated Proxy Enabled: 0\n'
        else
            printf 'Enabled: No\nServer: \nPort: 0\nAuthenticated Proxy Enabled: 0\n'
        fi
        ;;
    -setwebproxystate|-setsecurewebproxystate|-setsocksfirewallproxystate)
        svc="$1"
        val="$2"
        kind="${cmd#-set}"
        kind="${kind%state}"
        state_file="$MOCK_STATE_DIR/${kind}_$(printf '%s' "$svc" | tr ' /' '__')"
        srv="127.0.0.1"
        port="7897"
        if [[ -f "$state_file" ]]; then
            srv="$(sed -n 's/^Server: //p' "$state_file")"
            port="$(sed -n 's/^Port: //p' "$state_file")"
        fi
        en="No"
        [[ "$val" == "on" ]] && en="Yes"
        printf 'Enabled: %s\nServer: %s\nPort: %s\nAuthenticated Proxy Enabled: 0\n' "$en" "$srv" "$port" > "$state_file"
        ;;
    -setwebproxy|-setsecurewebproxy|-setsocksfirewallproxy)
        svc="$1"
        srv="$2"
        port="$3"
        kind="${cmd#-set}"
        state_file="$MOCK_STATE_DIR/${kind}_$(printf '%s' "$svc" | tr ' /' '__')"
        # Mirrors macOS behavior: -set*proxy turns proxy on!
        printf 'Enabled: Yes\nServer: %s\nPort: %s\nAuthenticated Proxy Enabled: 0\n' "$srv" "$port" > "$state_file"
        ;;
    -getautoproxyurl)
        svc="$1"
        state_file="$MOCK_STATE_DIR/autoproxy_$(printf '%s' "$svc" | tr ' /' '__')"
        if [[ -f "$state_file" ]]; then
            cat "$state_file"
        elif [[ "$svc" == "Wi-Fi" ]]; then
            printf 'URL: http://127.0.0.1:7897/pac\nEnabled: Yes\n'
        else
            printf 'URL: (null)\nEnabled: No\n'
        fi
        ;;
    -setautoproxyurl)
        svc="$1"
        url="$2"
        state_file="$MOCK_STATE_DIR/autoproxy_$(printf '%s' "$svc" | tr ' /' '__')"
        printf 'URL: %s\nEnabled: Yes\n' "$url" > "$state_file"
        ;;
    -setautoproxystate)
        svc="$1"
        val="$2"
        state_file="$MOCK_STATE_DIR/autoproxy_$(printf '%s' "$svc" | tr ' /' '__')"
        url=""
        [[ -f "$state_file" ]] && url="$(sed -n 's/^URL: //p' "$state_file")"
        en="No"
        [[ "$val" == "on" ]] && en="Yes"
        printf 'URL: %s\nEnabled: %s\n' "$url" "$en" > "$state_file"
        ;;
    -getproxyautodiscovery)
        svc="$1"
        state_file="$MOCK_STATE_DIR/autodisc_$(printf '%s' "$svc" | tr ' /' '__')"
        if [[ -f "$state_file" ]]; then
            cat "$state_file"
        else
            echo "Auto Proxy Discovery: Off"
        fi
        ;;
    -setproxyautodiscovery)
        svc="$1"
        val="$2"
        state_file="$MOCK_STATE_DIR/autodisc_$(printf '%s' "$svc" | tr ' /' '__')"
        [[ "$val" == "on" ]] && echo "Auto Proxy Discovery: On" > "$state_file" || echo "Auto Proxy Discovery: Off" > "$state_file"
        ;;
    -getdnsservers)
        if [[ -f "$MOCK_STATE_DIR/dns_empty" ]]; then
            echo "There aren't any DNS Servers set on $1."
        else
            echo "114.114.114.114"
        fi
        ;;
    -setdnsservers)
        if [[ "$2" == "Empty" ]]; then
            touch "$MOCK_STATE_DIR/dns_empty"
        fi
        ;;
    -getinfo)
        if [[ -f "$MOCK_STATE_DIR/manual_ip" ]]; then
            echo "Manual Configuration"
        else
            printf 'DHCP Configuration\nIP address: 10.175.13.18\n'
        fi
        ;;
    -setdhcp)
        rm -f "$MOCK_STATE_DIR/manual_ip"
        ;;
    -getairportpower)
        echo "Wi-Fi Power (en0): On"
        ;;
    -setairportpower)
        ;;
    *)
        ;;
esac
EOF

cat > "$MOCK_BIN/dscacheutil" <<'EOF'
#!/usr/bin/env bash
echo "dscacheutil $*" >> "$MOCK_CALL_LOG"
if [[ "$1" == "-q" && -f "$MOCK_STATE_DIR/fake_ip" ]]; then
    printf 'name: captive.apple.com\nip_address: 28.0.0.35\n'
fi
EOF

cat > "$MOCK_BIN/killall" <<'EOF'
#!/usr/bin/env bash
echo "killall $*" >> "$MOCK_CALL_LOG"
EOF

cat > "$MOCK_BIN/arp" <<'EOF'
#!/usr/bin/env bash
echo "arp $*" >> "$MOCK_CALL_LOG"
if [[ "$1" == "-d" ]]; then
    touch "$MOCK_STATE_DIR/arp_flushed"
    exit 1  # Simulate permanent multicast entry causing non-zero exit
fi
if [[ "$1" == "-an" ]]; then
    echo "mdns.mcast.net (224.0.0.251) at 1:0:5e:0:0:fb on en0 ifscope permanent [ethernet]"
    if [[ ! -f "$MOCK_STATE_DIR/arp_flushed" ]]; then
        echo "? (10.175.13.63) at 8a:a:76:33:30:f3 on en0 ifscope [ethernet]"
    fi
fi
EOF

cat > "$MOCK_BIN/ifconfig" <<'EOF'
#!/usr/bin/env bash
echo "ifconfig $*" >> "$MOCK_CALL_LOG"
if [[ "$1" == "en0" && -z "$2" ]]; then
    if [[ -f "$MOCK_STATE_DIR/link_inactive" ]]; then
        echo "	status: inactive"
    else
        echo "	status: active"
    fi
fi
EOF

cat > "$MOCK_BIN/scutil" <<'EOF'
#!/usr/bin/env bash
echo "scutil $*" >> "$MOCK_CALL_LOG"
EOF

cat > "$MOCK_BIN/ipconfig" <<'EOF'
#!/usr/bin/env bash
cmd="$1"
case "$cmd" in
    getifaddr)
        if [[ -f "$MOCK_STATE_DIR/bad_ip" ]]; then
            echo "169.254.12.34"
        else
            echo "10.175.13.18"
        fi
        ;;
    getsummary)
        echo "State : BOUND"
        ;;
    getoption)
        if [[ "$3" == "router" ]]; then
            echo "10.175.13.63"
        else
            echo "10.175.13.63"
        fi
        ;;
esac
EOF

cat > "$MOCK_BIN/route" <<'EOF'
#!/usr/bin/env bash
if [[ "$3" == "28.0.0.35" || "$3" == "8.8.8.8" ]] && [[ -f "$MOCK_STATE_DIR/fake_ip" ]]; then
    echo "  interface: utun4"
else
    echo "  interface: en0"
fi
EOF

cat > "$MOCK_BIN/launchctl" <<'EOF'
#!/usr/bin/env bash
echo "launchctl $*" >> "$MOCK_CALL_LOG"
EOF

cat > "$MOCK_BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
if [[ -f "$MOCK_STATE_DIR/fake_ip" && "$2" == "verge-mihomo" ]]; then
    echo "93915"
    exit 0
fi
exit 1
EOF

cat > "$MOCK_BIN/ping" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$MOCK_BIN/nc" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$MOCK_BIN/dig" <<'EOF'
#!/usr/bin/env bash
echo "17.253.144.10"
EOF

cat > "$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
hdr=""
out=""
url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -D) hdr="$2"; shift 2 ;;
        -o) out="$2"; shift 2 ;;
        -w|--connect-timeout|--max-time|--noproxy) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
if [[ "$url" == *"captive.apple.com"* ]]; then
    if [[ -f "$MOCK_STATE_DIR/portal_stall" ]]; then
        printf 'HTTP/1.1 302 Found\r\nLocation: http://10.162.255.1/login\r\n\r\n' > "$hdr"
        printf '302'
        exit 0
    fi
    printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr"
    printf '<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>' > "$out"
    printf '200'
    exit 0
fi
if [[ "$url" == "http://10.162.255.1/login" ]]; then
    printf '000'
    exit 28
fi
printf '200'
EOF

cat > "$MOCK_BIN/log" <<'EOF'
#!/usr/bin/env bash
if [[ -f "$MOCK_STATE_DIR/portal_stall" ]]; then
    echo "2026-11-16 16:04:27.761 Df captiveagent: received response, status 302"
    echo "2026-11-16 16:04:59.162 Df captiveagent: event: flow:connect_stalled @2.002s"
    echo "2026-11-16 16:05:08.760 Df configd: en0: probed timed out for the Wi-Fi network, assuming online"
fi
EOF

cat > "$MOCK_BIN/xattr" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$MOCK_BIN"/*
export PATH="$MOCK_BIN:/usr/bin:/bin"

assert_contains() {
    local haystack="$1" needle="$2" label="$3"
    if ! printf '%s\n' "$haystack" | grep -Fq -- "$needle"; then
        echo "ASSERTION FAILED [$label]: expected to find '$needle'" >&2
        printf '%s\n' "$haystack" >&2
        exit 1
    fi
}

echo "[Test 1] bash -n syntax check"
/bin/bash -n "$TARGET"
/bin/bash -n "$REPO_DIR/scripts/fix_net.command"
/bin/bash -n "$REPO_DIR/scripts/diagnose_net.command"

echo "[Test 2] --status and --dry-run (non-root)"
export MOCK_UID=501
status_out="$(/bin/bash "$TARGET" --status)"
assert_contains "$status_out" "目标服务：Wi-Fi" "status service"
assert_contains "$status_out" "网卡接口：en0" "status device"
dry_out="$(/bin/bash "$TARGET" --dry-run --reset-dns)"
assert_contains "$dry_out" "networksetup -setdnsservers \"Wi-Fi\" Empty" "dry-run reset-dns"

echo "[Test 3] full repair flow (proxies off & cleared, DNS, ARP permanent skip, DHCP bound)"
export MOCK_UID=0
touch "$MOCK_STATE_DIR/manual_ip"
: > "$LOG_FILE"
run_out="$(/bin/bash "$TARGET" --no-startup-prompt --reset-dns)"
assert_contains "$run_out" "[完成] 系统代理已关闭（已覆盖 3 个启用服务）" "disable proxies"
assert_contains "$run_out" "[完成] 代理地址和 PAC 已清理" "clear proxies"
assert_contains "$run_out" "[完成] DNS 缓存已刷新" "flush dns"
assert_contains "$run_out" "[完成] 已清除手动 DNS（114.114.114.114）" "reset dns"
assert_contains "$run_out" "[完成] ARP 缓存已清理" "clear arp"
assert_contains "$run_out" "[完成] 已将 Wi-Fi 设为 DHCP 自动获取" "setdhcp"
assert_contains "$run_out" "[完成] 已触发 en0 DHCP 续租请求" "scutil renew"
assert_contains "$run_out" "[完成] DHCP 租约正常：IP=10.175.13.18" "dhcp bound"
assert_contains "$(cat "$STATE_DIR/webproxy_Wi-Fi")" "Enabled: No" "webproxy stays off after clear"
assert_contains "$(cat "$STATE_DIR/autoproxy_Wi-Fi")" "Enabled: No" "autoproxy stays off after clear"
assert_contains "$(cat "$LOG_FILE")" "networksetup -setwebproxystate EnAgent-VPN off" "secondary service cleared"

echo "[Test 4] --install-desktop creates standalone fix_net.command and diagnose_net.command"
export MOCK_UID=501
desk_out="$(/bin/bash "$TARGET" --install-desktop)"
assert_contains "$desk_out" "$HOME_DIR/Desktop/fix_net.command" "desktop output"
assert_contains "$desk_out" "$HOME_DIR/Desktop/diagnose_net.command" "desktop diagnose output"
[[ -x "$HOME_DIR/Desktop/fix_net.command" ]]
[[ -x "$HOME_DIR/Desktop/diagnose_net.command" ]]

echo "[Test 5] --install-startup, --startup on inactive link, and --remove-startup"
export MOCK_UID=0
/bin/bash "$TARGET" --install-startup >/dev/null
[[ -f "$DAEMONS_DIR/com.campus-net-login.fix-net.plist" ]]
[[ -x "$SUPPORT_DIR/fix_net.sh" ]]
assert_contains "$(cat "$DAEMONS_DIR/com.campus-net-login.fix-net.plist")" "<string>--startup</string>" "plist startup flag"

touch "$MOCK_STATE_DIR/link_inactive"
startup_out="$(/bin/bash "$TARGET" --startup)"
assert_contains "$startup_out" "[跳过] 开机启动时 en0 尚未连接" "startup skips inactive dhcp"
rm -f "$MOCK_STATE_DIR/link_inactive"

rm_out="$(/bin/bash "$TARGET" /remove-startup)"
assert_contains "$rm_out" "已移除开机启动" "remove startup"
[[ ! -f "$DAEMONS_DIR/com.campus-net-login.fix-net.plist" ]]

echo "[Test 6] link-local 169.254.x.x returns non-zero with --hard hint"
touch "$MOCK_STATE_DIR/bad_ip"
set +e
bad_out="$(/bin/bash "$TARGET" --no-startup-prompt)"
bad_rc=$?
set -e
[[ "$bad_rc" -eq 1 ]]
assert_contains "$bad_out" "[失败] 未获取到有效 DHCP 地址（当前：169.254.12.34）" "apipa failure"
assert_contains "$bad_out" "--hard" "hard hint"
rm -f "$MOCK_STATE_DIR/bad_ip"

echo "[Test 7] split-route utun, Fake-IP, and proxy process detection hints"
touch "$MOCK_STATE_DIR/fake_ip"
fake_out="$(/bin/bash "$TARGET" --status)"
assert_contains "$fake_out" "虚拟网卡 (utun4)" "split-route tun hint"
assert_contains "$fake_out" "Fake-IP (28.0.0.35)" "fake-ip captive hint"
assert_contains "$fake_out" "代理进程 (verge-mihomo)" "running proxy process hint"
rm -f "$MOCK_STATE_DIR/fake_ip"

echo "[Test 8] --diagnose detects 302 portal stall, assuming-online verdict, and --save"
touch "$MOCK_STATE_DIR/portal_stall"
report_file="$TMP_ROOT/report.txt"
diag_out="$(/bin/bash "$TARGET" --diagnose --save "$report_file")"
assert_contains "$diag_out" "捕获跳转认证地址：http://10.162.255.1/login" "diagnose 302 location"
assert_contains "$diag_out" "认证服务器响应超时/卡死" "diagnose portal stall"
assert_contains "$diag_out" "assuming online" "diagnose log assuming online"
[[ -s "$report_file" ]]
rm -f "$MOCK_STATE_DIR/portal_stall"

echo "ALL TESTS PASSED"
