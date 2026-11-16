#!/usr/bin/env bash
# Double-clickable macOS Terminal launcher for fix_net.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/fix_net.sh"

if [[ ! -f "$TARGET_SCRIPT" ]]; then
    echo "[失败] 未找到同目录下的 fix_net.sh：$TARGET_SCRIPT" >&2
    echo "如果你需要把独立脚本放到桌面，请在项目目录执行：" >&2
    echo "  bash scripts/fix_net.sh --install-desktop" >&2
    printf '按回车键关闭窗口...'
    read -r _
    exit 1
fi

exec bash "$TARGET_SCRIPT" --pause "$@"
