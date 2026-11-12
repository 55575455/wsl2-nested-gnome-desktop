#!/usr/bin/env bash
# =====================================================================
#  为 Ubuntu 26.04 的嵌套 GNOME 桌面开启 GNOME Remote Desktop (RDP)
# ---------------------------------------------------------------------
#  用途：从 Windows 自带的“远程桌面连接”连 localhost:3390，
#        从而获得登录界面（greeter）、全屏、剪贴板等嵌套方案缺失的能力。
#  前提：已运行 wsl-desktop-2604.sh 并确认桌面能起来；WSL 已开启 systemd。
#
#  用法（在 Ubuntu 26.04 的 WSL 终端里）：
#    sudo bash wsl-desktop-2604-rdp.sh
#
#  完成后：
#    Windows 终端：wsl.exe --shutdown
#    重开 Ubuntu 终端：~/start-desktop.sh
#    检查端口：sudo ss -ltnp | grep ':3390'
#    Windows 远程桌面连接 → localhost:3390 → 用设置的密码登录
# =====================================================================
set -euo pipefail

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
  warn "需要 root 权限，正在通过 sudo 重新执行…"
  exec sudo -E bash "$0" "$@"
fi

TARGET_USER="${SUDO_USER:-}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
  TARGET_USER="$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd || true)"
fi
[ -n "$TARGET_USER" ] || die "找不到普通用户"

[ -r /etc/os-release ] || die "无法读取 /etc/os-release"
# shellcheck disable=SC1091
. /etc/os-release
if [ "${VERSION_ID:-}" != "26.04" ]; then
  warn "当前发行版：${PRETTY_NAME:-未知}；本脚本针对 Ubuntu 26.04 的配方。"
  [ "${WSL_DESKTOP_FORCE:-0}" = "1" ] || die "如确定要试，设置 WSL_DESKTOP_FORCE=1 后重跑。"
fi
[ -d /run/systemd/system ] || die "systemd 未运行。请先在 /etc/wsl.conf 开启 systemd=true 并 wsl --shutdown 重启。"

log "1/4 安装 gnome-remote-desktop 与 openssl"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y gnome-remote-desktop openssl

log "2/4 生成 TLS 证书"
install -d -m 0700 /etc/gnome-remote-desktop
if [ ! -f /etc/gnome-remote-desktop/rdp-cert.pem ] || [ ! -f /etc/gnome-remote-desktop/rdp-key.pem ]; then
  openssl req -x509 -newkey rsa:4096 -nodes \
    -keyout /etc/gnome-remote-desktop/rdp-key.pem \
    -out /etc/gnome-remote-desktop/rdp-cert.pem \
    -days 3650 -subj "/CN=$(hostname)"
fi
if id -u gnome-remote-desktop >/dev/null 2>&1; then
  chown gnome-remote-desktop:gnome-remote-desktop /etc/gnome-remote-desktop/rdp-key.pem
else
  warn "系统中没有 gnome-remote-desktop 用户，跳过属主设置。"
fi
chmod 600 /etc/gnome-remote-desktop/rdp-key.pem

log "3/4 配置 RDP（端口 3390）"
grdctl --system rdp enable
grdctl --system rdp set-port 3390
grdctl --system rdp set-tls-cert /etc/gnome-remote-desktop/rdp-cert.pem
grdctl --system rdp set-tls-key /etc/gnome-remote-desktop/rdp-key.pem
echo
warn "接下来会为 $TARGET_USER 设置 RDP 登录密码（Windows 远程桌面里使用）。"
grdctl --system rdp set-credentials "$TARGET_USER"

log "4/4 状态检查"
grdctl --system status || true

cat <<'EOF'

完成。
接下来：
  1) Windows 终端执行：wsl.exe --shutdown
  2) 重开 Ubuntu 26.04 终端：~/start-desktop.sh
  3) 确认端口：sudo ss -ltnp | grep ':3390'   （应看到 LISTEN）
  4) Windows 打开“远程桌面连接”，计算机填 localhost:3390，
     用户名/密码用上一步为你的 Ubuntu 用户设置的 RDP 密码。

已知现象（来自社区反馈）：
  * 连接瞬间可能闪一个黑色 RDP 窗口，随后消失并弹出登录界面；
  * 登录后旧登录窗口可能变黑但不自动关闭，手动关闭即可；
  * VS Code 等应用可能仍以独立 WSLg 窗口打开，而不是留在桌面窗口内。
EOF
