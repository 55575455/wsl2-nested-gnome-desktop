#!/usr/bin/env bash
# =====================================================================
#  WSL2 + Ubuntu 26.04：嵌套 GNOME 桌面（Wayland / mutter devkit）
# ---------------------------------------------------------------------
#  说明：
#    这是目前 Ubuntu 26.04（GNOME 50）上可用的 WSL GNOME 桌面方案。
#    它 **不是** Xwayland 方案：26.04 已移除 X11 会话且 GDM 不再支持
#    X11，原 Xwayland 教程（替换 Xorg + GDM 登录会话）无法运行。
#    本脚本实现的是社区配方（tdcosta100 gist 评论区 2026-08），
#    作者未合并进正文，本人也未在真机验证，请先在可丢弃的实例上试。
#
#  用法（在 Ubuntu 26.04 的 WSL 终端里）：
#    sudo bash wsl-desktop-2604.sh              # 先看计划（推荐）
#    sudo bash wsl-desktop-2604.sh --yes        # 真正执行
#    sudo bash wsl-desktop-2604.sh --full       # 安装完整桌面（更重）
#    sudo bash wsl-desktop-2604.sh --rollback   # 撤销本脚本的改动
#
#  完成后：
#    Windows 终端执行：wsl.exe --shutdown
#    重新打开 Ubuntu 26.04 终端，执行：~/start-desktop.sh
# =====================================================================
set -euo pipefail

ASSUME_YES=0
ROLLBACK=0
FULL=0

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
用法：sudo bash wsl-desktop-2604.sh [选项]

  -y, --yes        不再询问，直接执行（“一键”模式）
  --full           安装完整 ubuntu-desktop（不加 --no-install-recommends）
  --rollback       撤销本脚本做的配置（不卸载软件包）
  -h, --help       显示本帮助

仅适用于 WSL2 里的 Ubuntu 26.04 + WSLg；需要 /etc/wsl.conf 开启 systemd=true。
USAGE
}

for arg in "$@"; do
  case "$arg" in
    -y|--yes)   ASSUME_YES=1 ;;
    --full)     FULL=1 ;;
    --rollback) ROLLBACK=1 ;;
    -h|--help)  usage; exit 0 ;;
    *) die "未知参数：$arg（用 --help 查看用法）" ;;
  esac
done

# ---- 权限 ----
if [ "$(id -u)" -ne 0 ]; then
  warn "需要 root 权限，正在通过 sudo 重新执行…"
  exec sudo -E bash "$0" "$@"
fi

# ---- 识别目标用户（桌面必须以普通用户身份启动）----
TARGET_USER="${SUDO_USER:-}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
  TARGET_USER="$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd || true)"
fi
[ -n "$TARGET_USER" ] || die "找不到普通用户。请先在 Ubuntu 里创建用户（首次启动会提示），再运行本脚本。"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$TARGET_HOME" ] || die "无法确定 $TARGET_USER 的家目录"

# ---- 环境检查 ----
[ -r /etc/os-release ] || die "无法读取 /etc/os-release"
# shellcheck disable=SC1091
. /etc/os-release
if [ "${VERSION_ID:-}" != "26.04" ]; then
  warn "当前发行版：${PRETTY_NAME:-未知}（VERSION_ID=${VERSION_ID:-?}），本脚本只针对 Ubuntu 26.04。"
  [ "${WSL_DESKTOP_FORCE:-0}" = "1" ] || die "如确定要试，设置环境变量 WSL_DESKTOP_FORCE=1 后重跑。"
fi
if ! grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null && [ ! -d /mnt/wslg ]; then
  die "看起来不是 WSL2 环境（或 WSLg 未启用），本脚本只用于 WSL2。"
fi
[ -d /mnt/wslg ] || warn "未检测到 /mnt/wslg：WSLg 可能未启用，桌面可能无法显示。"

# ---- systemd 检查 / 自动补 wsl.conf ----
if [ ! -d /run/systemd/system ] && [ "$ROLLBACK" -eq 0 ]; then
  if [ -f /etc/wsl.conf ] && grep -q '^\[boot\]' /etc/wsl.conf 2>/dev/null && \
     awk '/^\[boot\]/{f=1;next} /^\[/{f=0} f && /^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true/{found=1} END{exit !found}' /etc/wsl.conf; then
    die "systemd 已配置但当前未生效：请在 Windows 执行 wsl.exe --shutdown，重开 Ubuntu 后再运行本脚本。"
  fi
  warn "systemd 未启用，本方案依赖 systemd 用户单元。"
  if [ "$ASSUME_YES" -eq 1 ]; then
    if grep -q '^\[boot\]' /etc/wsl.conf 2>/dev/null; then
      printf 'systemd=true\n' >> /etc/wsl.conf
    else
      printf '\n[boot]\nsystemd=true\n' >> /etc/wsl.conf
    fi
    die "已写入 /etc/wsl.conf。请执行 wsl.exe --shutdown，重开 Ubuntu 后再运行本脚本。"
  fi
  read -r -p "现在自动在 /etc/wsl.conf 写入 [boot] systemd=true 吗？[y/N] " ans
  case "${ans:-}" in
    y|Y|yes|YES)
      if grep -q '^\[boot\]' /etc/wsl.conf 2>/dev/null; then
        printf 'systemd=true\n' >> /etc/wsl.conf
      else
        printf '\n[boot]\nsystemd=true\n' >> /etc/wsl.conf
      fi
      die "已写入 /etc/wsl.conf。请执行 wsl.exe --shutdown，重开 Ubuntu 后再运行本脚本。"
      ;;
  esac
  die "已取消。请手动在 /etc/wsl.conf 添加 [boot] systemd=true 并重启 WSL。"
fi

# ---- 回滚 ----
if [ "$ROLLBACK" -eq 1 ]; then
  log "撤销 26.04 嵌套 GNOME 配置"
  rm -f /etc/systemd/user/org.gnome.Shell@.service.d/override.conf
  rmdir /etc/systemd/user/org.gnome.Shell@.service.d 2>/dev/null || true
  rm -f "$TARGET_HOME/start-desktop.sh"
  warn "已删除 override 与启动脚本；ubuntu-desktop / mutter-dev-bin 等软件包未卸载。"
  warn "如需彻底清理，最干净的做法是备份数据后重建该 WSL 发行版。"
  exit 0
fi

# ---- 计划 ----
echo
echo "即将执行（发行版：${PRETTY_NAME:-Ubuntu}，桌面用户：$TARGET_USER）："
if [ "$FULL" -eq 1 ]; then
  echo "  1) apt-get update"
  echo "  2) 安装完整 ubuntu-desktop"
else
  echo "  1) apt-get update"
  echo "  2) 安装 ubuntu-desktop（--no-install-recommends，约 1~2 GB）"
fi
echo "  3) 安装 snap-store（失败可忽略）"
echo "  4) 安装 mutter-dev-bin（GNOME 50 嵌套模式必需）"
echo "  5) 写 /etc/systemd/user/org.gnome.Shell@.service.d/override.conf"
echo "  6) 生成 $TARGET_HOME/start-desktop.sh"
echo
warn "这是社区配方，非官方方案；请先备份重要数据，最好用独立的 WSL 发行版实验。"
if [ "$ASSUME_YES" -ne 1 ]; then
  read -r -p "继续？[y/N] " answer
  case "${answer:-}" in
    y|Y|yes|YES) ;;
    *) die "已取消。" ;;
  esac
fi

# ---- 执行 ----
export DEBIAN_FRONTEND=noninteractive

log "1/6 apt-get update"
apt-get update

log "2/6 安装桌面环境（最慢的一步，请耐心等待）"
if [ "$FULL" -eq 1 ]; then
  apt-get install -y ubuntu-desktop
else
  apt-get install -y --no-install-recommends ubuntu-desktop
fi
command -v gnome-session >/dev/null 2>&1 || die "gnome-session 未安装成功，请检查上面的 apt 输出。"

log "3/6 安装 snap-store（可选）"
if apt-get install -y snapd >/dev/null 2>&1 && snap install snap-store >/dev/null 2>&1; then
  echo "snap-store 已安装"
else
  warn "snap-store 安装失败，可忽略。"
fi

log "4/6 安装 mutter-dev-bin"
apt-get install -y mutter-dev-bin

log "5/6 写 GNOME Shell 用户单元 override"
install -d -m 0755 /etc/systemd/user/org.gnome.Shell@.service.d
cat > /etc/systemd/user/org.gnome.Shell@.service.d/override.conf <<'OVERRIDE'
[Service]
ExecStart=
ExecStart=/usr/bin/gnome-shell --devkit --no-x11 --mode=%i
OVERRIDE

log "6/6 生成启动脚本"
cat > "$TARGET_HOME/start-desktop.sh" <<'START'
#!/usr/bin/env bash
# 启动 WSL 里的嵌套 GNOME 桌面（Ubuntu 26.04 / GNOME 50）
# 可选：GALLIUM_DRIVER=d3d12 ~/start-desktop.sh  （尝试 GPU 加速，可能让 App Center 等崩溃）
set -euo pipefail
extra=()
[ -n "${GALLIUM_DRIVER:-}" ] && extra+=("GALLIUM_DRIVER=$GALLIUM_DRIVER")
exec env \
  XDG_CURRENT_DESKTOP=ubuntu:GNOME \
  XDG_SESSION_TYPE=wayland \
  "${extra[@]}" \
  gnome-session "$@"
START
chmod 0755 "$TARGET_HOME/start-desktop.sh"
chown "$TARGET_USER" "$TARGET_HOME/start-desktop.sh"

cat <<EOF

完成。
接下来：
  1) 在 Windows 终端执行：wsl.exe --shutdown
  2) 重新打开 Ubuntu 26.04 终端，执行：~/start-desktop.sh
  3) 第一次启动较慢；出现一个 GNOME 桌面窗口即成功。

已知限制：
  * 没有登录界面（除非另开 RDP：wsl-desktop-2604-rdp.sh）
  * 分辨率/全屏/剪贴板不完整
  * 这是社区配方，升级 WSL/GNOME 后可能失效

撤销：
  sudo bash $(basename "$0") --rollback
EOF
