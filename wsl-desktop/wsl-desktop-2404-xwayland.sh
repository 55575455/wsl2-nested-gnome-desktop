#!/usr/bin/env bash
# =====================================================================
#  WSL2 + Ubuntu 24.04：按 tdcosta100 的 Xwayland 教程自动配置完整桌面
# ---------------------------------------------------------------------
#  原教程：https://gist.github.com/tdcosta100/e28636c216515ca88d1f2e7a2e188912
#
#  重要：
#   * 仅适用于 Ubuntu 24.04（教程本身针对 24.04）。
#     26.04 已移除 X11 会话与 GDM 的 X11 支持，这套方案无法运行。
#   * 侵入性强：会替换 /usr/bin/Xorg、修改 gnome-session、改默认 target。
#   * 执行前先备份：wsl --export Ubuntu-24.04 D:\ubuntu2404-backup.tar
#   * 建议用独立、可丢弃的 WSL 发行版实验。
#
#  用法（在 Ubuntu 24.04 的 WSL 终端里）：
#    sudo bash wsl-desktop-2404-xwayland.sh                 # 查看计划
#    sudo bash wsl-desktop-2404-xwayland.sh --yes           # 执行
#    sudo bash wsl-desktop-2404-xwayland.sh --yes --resolution 2560x1440
#    sudo bash wsl-desktop-2404-xwayland.sh --rollback      # 撤销
#
#  完成后：
#    Windows 终端：wsl.exe --shutdown
#    重开 Ubuntu 24.04 终端，执行：sudo systemctl start graphical.target
# =====================================================================
set -euo pipefail

ASSUME_YES=0
ROLLBACK=0
UPGRADE=0
WITH_SNAP=0
RESOLUTION="1920x1080"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
用法：sudo bash wsl-desktop-2404-xwayland.sh [选项]

  -y, --yes            不再询问，直接执行（“一键”模式）
  --resolution WxH     虚拟桌面分辨率（默认 1920x1080，会同时写入 Xwayland 与 monitors.xml）
  --with-snap-store    额外安装 snap-store（原教程的可选步骤）
  --upgrade            先执行 apt-get upgrade（默认不升级，避免意外升级内核/驱动）
  --rollback           撤销本脚本的改动
  -h, --help           显示本帮助

仅适用于 WSL2 里的 Ubuntu 24.04 + WSLg；需要 /etc/wsl.conf 开启 systemd=true。
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)          ASSUME_YES=1 ;;
    --rollback)        ROLLBACK=1 ;;
    --upgrade)         UPGRADE=1 ;;
    --with-snap-store) WITH_SNAP=1 ;;
    --resolution)      shift; RESOLUTION="${1:-}" ;;
    -h|--help)         usage; exit 0 ;;
    *) die "未知参数：$1（用 --help 查看用法）" ;;
  esac
  shift || true
done

case "$RESOLUTION" in
  [0-9]*x[0-9]*) ;;
  *) die "--resolution 需要形如 1920x1080（收到：$RESOLUTION）" ;;
esac
W="${RESOLUTION%x*}"
H="${RESOLUTION#*x}"
[ -n "$W" ] && [ -n "$H" ] || die "--resolution 解析失败：$RESOLUTION"
case "$W" in ''|*[!0-9]*) die "--resolution 宽度不是数字：$W" ;; esac
case "$H" in ''|*[!0-9]*) die "--resolution 高度不是数字：$H" ;; esac

# ---- 权限 ----
if [ "$(id -u)" -ne 0 ]; then
  warn "需要 root 权限，正在通过 sudo 重新执行…"
  exec sudo -E bash "$0" "$@"
fi

# ---- 识别目标用户 ----
TARGET_USER="${SUDO_USER:-}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
  TARGET_USER="$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd || true)"
fi
[ -n "$TARGET_USER" ] || die "找不到普通用户。请先在 Ubuntu 里创建用户，再运行本脚本。"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$TARGET_HOME" ] || die "无法确定 $TARGET_USER 的家目录"

# ---- 环境检查 ----
[ -r /etc/os-release ] || die "无法读取 /etc/os-release"
# shellcheck disable=SC1091
. /etc/os-release
if [ "${VERSION_ID:-}" != "24.04" ]; then
  warn "当前发行版：${PRETTY_NAME:-未知}（VERSION_ID=${VERSION_ID:-?}）。"
  warn "本脚本只支持 Ubuntu 24.04。26.04 已移除 X11 会话，Xwayland 方案无法运行。"
  [ "${WSL_DESKTOP_FORCE:-0}" = "1" ] || die "如确定要试，设置 WSL_DESKTOP_FORCE=1 后重跑。"
fi
if ! grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null && [ ! -d /mnt/wslg ]; then
  die "看起来不是 WSL2 环境，本脚本只用于 WSL2。"
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
  log "回滚 Xwayland 教程改动"
  if update-alternatives --list Xorg 2>/dev/null | grep -qx '/usr/bin/Xorg.Xwayland'; then
    update-alternatives --remove Xorg /usr/bin/Xorg.Xwayland || true
  fi
  if [ -L /usr/bin/Xorg ]; then
    rm -f /usr/bin/Xorg
  fi
  if dpkg-divert --list /usr/bin/Xorg 2>/dev/null | grep -q 'diversion of /usr/bin/Xorg '; then
    dpkg-divert --local --rename --remove /usr/bin/Xorg || true
  fi
  rm -f /usr/bin/Xorg.Xwayland
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y --reinstall xserver-xorg-core gnome-session >/dev/null 2>&1 \
    || warn "重装 xserver-xorg-core / gnome-session 失败，请手动：sudo apt install --reinstall xserver-xorg-core gnome-session"
  systemctl disable --now wslg-fix.service 2>/dev/null || true
  rm -f /etc/systemd/system/wslg-fix.service
  systemctl daemon-reload || true
  rm -f /etc/systemd/user/wslg-session.service
  systemctl set-default graphical.target 2>/dev/null || true
  GDM_HOME="$(getent passwd gdm 2>/dev/null | cut -d: -f6 || true)"
  [ -n "${GDM_HOME:-}" ] && rm -rf "$GDM_HOME/.config"
  rm -f "$TARGET_HOME/.config/monitors.xml"
  warn "已回滚。若图形仍异常，建议备份数据后重建该发行版（原教程作者的忠告）。"
  exit 0
fi

# ---- 计划 ----
echo
echo "即将执行（发行版：${PRETTY_NAME:-Ubuntu}，用户：$TARGET_USER，分辨率：$RESOLUTION）："
echo "  1) apt-get update$([ "$UPGRADE" -eq 1 ] && echo ' + apt-get upgrade')"
echo "  2) 安装 ubuntu-desktop xwayland$([ "$WITH_SNAP" -eq 1 ] && echo ' + snap-store')"
echo "  3) 创建并启用 wslg-fix.service（修复只读 /tmp/.X11-unix）"
echo "  4) mask wslg-session（阻止应用跑出桌面）"
echo "  5) 给 gnome-session 加 --disable-acceleration-check"
echo "  6) systemctl set-default multi-user.target"
echo "  7) 安装 /usr/bin/Xorg.Xwayland 并替换系统 Xorg（dpkg-divert + update-alternatives）"
echo "  8) 写 ~/.config/monitors.xml 并复制给 GDM（强制 ${W}x${H}）"
echo
warn "本方案会修改系统关键文件；请先备份 WSL 发行版，最好在独立实例上实验。"
if [ "$ASSUME_YES" -ne 1 ]; then
  read -r -p "继续？[y/N] " answer
  case "${answer:-}" in
    y|Y|yes|YES) ;;
    *) die "已取消。" ;;
  esac
fi

export DEBIAN_FRONTEND=noninteractive

log "1/8 apt-get update"
apt-get update
if [ "$UPGRADE" -eq 1 ]; then
  apt-get upgrade -y
fi

log "2/8 安装 ubuntu-desktop 与 xwayland（最慢的一步）"
apt-get install -y ubuntu-desktop xwayland
if [ "$WITH_SNAP" -eq 1 ]; then
  if apt-get install -y snapd >/dev/null 2>&1 && snap install snap-store >/dev/null 2>&1; then
    echo "snap-store 已安装"
  else
    warn "snap-store 安装失败，可忽略。"
  fi
fi
command -v Xwayland >/dev/null 2>&1 || die "Xwayland 未安装成功，请检查 apt 输出。"
command -v gnome-session >/dev/null 2>&1 || die "gnome-session 未安装成功，请检查 apt 输出。"

log "3/8 创建 wslg-fix.service"
cat > /etc/systemd/system/wslg-fix.service <<'UNIT'
[Unit]
After=wslg.service

[Service]
Type=oneshot
ExecStart=-/usr/bin/umount /tmp/.X11-unix
ExecStart=/usr/bin/rm -rf /tmp/.X11-unix
ExecStart=/usr/bin/mkdir -m 1777 /tmp/.X11-unix
ExecStart=/usr/bin/ln -s /mnt/wslg/.X11-unix/X0 /tmp/.X11-unix/X0
ExecStart=/usr/bin/chmod 0666 /mnt/wslg/runtime-dir/wayland-0.lock

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable wslg-fix.service

log "4/8 mask wslg-session（阻止 WSLg 默认会话把应用抓到桌面外）"
install -d -m 0755 /etc/systemd/user
if [ -e /etc/systemd/user/wslg-session.service ] && [ ! -L /etc/systemd/user/wslg-session.service ]; then
  mv /etc/systemd/user/wslg-session.service /etc/systemd/user/wslg-session.service.bak
fi
ln -sf /dev/null /etc/systemd/user/wslg-session.service

log "5/8 给 gnome-session 加 --disable-acceleration-check"
if [ -f /usr/bin/gnome-session ]; then
  if ! grep -q -- '--disable-acceleration-check' /usr/bin/gnome-session; then
    sed -i 's/gnome-session-binary/gnome-session-binary --disable-acceleration-check/' /usr/bin/gnome-session
  fi
else
  warn "/usr/bin/gnome-session 不存在，跳过此步。"
fi

log "6/8 把默认启动 target 改为 multi-user.target"
systemctl set-default multi-user.target

log "7/8 安装 Xorg.Xwayland 替换脚本并替换系统 Xorg"
cat > /usr/bin/Xorg.Xwayland <<'XORG'
#!/bin/bash
for arg do
  shift
  case $arg in
    # Xwayland doesn't support vtxx argument. So we convert to ttyxx instead
    vt*)
      set -- "$@" "${arg//vt/tty}"
      ;;
    # -keeptty is not supported at all by Xwayland
    -keeptty)
      ;;
    # -novtswitch is not supported at all by Xwayland
    -novtswitch)
      ;;
    # other arguments are kept intact
    *)
      set -- "$@" "$arg"
      ;;
  esac
done

# Check if the runtime dir is present, and create it if not
if [ ! -d $HOME/runtime-dir ]
then
 mkdir $HOME/runtime-dir
 ln -s /mnt/wslg/runtime-dir/wayland-0 /mnt/wslg/runtime-dir/wayland-0.lock $HOME/runtime-dir/
fi

# Point the XDG_RUNTIME_DIR variable to $HOME/runtime-dir
export XDG_RUNTIME_DIR=$HOME/runtime-dir

# Find an available display number
for displayNumber in $(seq 1 100)
do
  [ ! -e /tmp/.X11-unix/X$displayNumber ] && break
done

# Here you can change or add options to fit your needs
command=("/usr/bin/Xwayland" ":${displayNumber}" "-geometry" "__RES__" "-fullscreen" "$@")

systemd-cat -t /usr/bin/Xorg echo "Starting Xwayland:" "${command[@]}"

exec "${command[@]}"
XORG
sed -i "s/__RES__/${RESOLUTION}/" /usr/bin/Xorg.Xwayland
chmod 0755 /usr/bin/Xorg.Xwayland
chown root:root /usr/bin/Xorg.Xwayland

if ! dpkg-divert --list /usr/bin/Xorg 2>/dev/null | grep -q 'diversion of /usr/bin/Xorg '; then
  dpkg-divert --local --add --rename /usr/bin/Xorg
else
  echo "Xorg 已处于 divert 状态，跳过。"
fi
update-alternatives --install /usr/bin/Xorg Xorg /usr/bin/Xorg.Xwayland 100

log "8/8 写 ${W}x${H} 的 monitors.xml"
if [ ! -d "$TARGET_HOME/.config" ]; then
  install -d -m 0755 "$TARGET_HOME/.config"
  chown "$TARGET_USER:$(id -gn "$TARGET_USER")" "$TARGET_HOME/.config"
fi
if [ -f "$TARGET_HOME/.config/monitors.xml" ]; then
  cp "$TARGET_HOME/.config/monitors.xml" "$TARGET_HOME/.config/monitors.xml.bak.$(date +%s)"
fi
cat > "$TARGET_HOME/.config/monitors.xml" <<'MON'
<monitors version="2">
  <configuration>
    <logicalmonitor>
      <x>0</x>
      <y>0</y>
      <scale>1</scale>
      <primary>yes</primary>
      <monitor>
        <monitorspec>
          <connector>XWAYLAND0</connector>
          <vendor>unknown</vendor>
          <product>unknown</product>
          <serial>unknown</serial>
        </monitorspec>
        <mode>
          <width>__W__</width>
          <height>__H__</height>
          <rate>59.963</rate>
        </mode>
      </monitor>
    </logicalmonitor>
  </configuration>
</monitors>
MON
sed -i "s/__W__/${W}/; s/__H__/${H}/" "$TARGET_HOME/.config/monitors.xml"
chown "$TARGET_USER" "$TARGET_HOME/.config/monitors.xml"

GDM_HOME="$(getent passwd gdm 2>/dev/null | cut -d: -f6 || true)"
if [ -n "${GDM_HOME:-}" ] && id -u gdm >/dev/null 2>&1; then
  install -d -m 0755 "$GDM_HOME/.config"
  cp "$TARGET_HOME/.config/monitors.xml" "$GDM_HOME/.config/monitors.xml"
  chown -R gdm:gdm "$GDM_HOME/.config"
else
  warn "未找到 gdm 用户，跳过 GDM 的 monitors.xml（发行版可能不使用 gdm3）。"
fi

cat <<EOF

完成。
接下来：
  1) Windows 终端执行：wsl.exe --shutdown
  2) 重新打开 Ubuntu 24.04 终端
  3) 执行：sudo systemctl start graphical.target
  4) 稍等片刻应出现 GDM 登录界面，用你的 Ubuntu 用户名/密码登录

注意：
  * 退出时请走桌面菜单“关机”或 sudo poweroff，等 WSL 结束后再 wsl --shutdown。
  * 若想开机自动进入图形：sudo systemctl enable graphical.target（有评论反馈可行，可选）。
  * 系统升级可能覆盖 /usr/bin/Xorg 或 gnome-session，届时重跑本脚本或对应步骤。
  * 撤销：sudo bash $(basename "$0") --rollback
EOF
