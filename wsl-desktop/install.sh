#!/usr/bin/env bash
# 跨发行版安装器：在 WSL 里以 root 运行（由 oneclick/install.ps1 自动调用）
#
#   bash install.sh [--user 用户名] [--skip-packages]
#
# 支持：Ubuntu / Kali / Debian（apt），Fedora / Oracle Linux / RHEL（dnf）
# 做的事：
#   1) 确保 WSL 里 systemd 已开启（没开就写 /etc/wsl.conf 并退出码 3，让 Windows 侧重启发行版后重试）
#   2) 确保有一个普通用户（没有就创建 u，并写 sudo 免密 / 设为默认用户）
#   3) 安装对应发行版的 GNOME 桌面（GNOME >= 49 用 devkit；GNOME 47/48 用嵌套模式）
#   4) 安装音频（WSLg PulseServer + PipeWire）与剪贴板同步
#   5) 部署 ~/start-desktop.sh / ~/stop-desktop.sh
#
# 退出码：0 成功；3 需要 wsl --terminate 后重跑；1 失败
set -u

USER_NAME=""
SKIP_PACKAGES=0
for arg in "$@"; do
  case "$arg" in
    --user=*)        USER_NAME="${arg#*=}" ;;
    --skip-packages) SKIP_PACKAGES=1 ;;
    -h|--help)
      sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "未知参数：$arg" >&2; exit 2 ;;
  esac
done

[ "$(id -u)" = 0 ] || { echo "请用 root 运行：wsl -d <发行版> -u root -- bash install.sh" >&2; exit 1; }

say() { echo "[wsl-desktop] $*"; }
warn() { echo "[wsl-desktop][!] $*" >&2; }

SRC=$(cd "$(dirname "$0")" && pwd)
[ -f "$SRC/audio/install-audio.sh" ] || { echo "安装包不完整：找不到 $SRC/audio/install-audio.sh" >&2; exit 1; }

if [ -r /etc/os-release ]; then . /etc/os-release; fi
DISTRO_ID="${ID:-unknown}"
DISTRO_PRETTY="${PRETTY_NAME:-$DISTRO_ID}"
WSL_DISTRO="${WSL_DISTRO_NAME:-$DISTRO_ID}"

# ---------- 0) systemd ----------
# 我们的桌面/剪贴板服务都靠 systemd 用户单元托管，WSL 必须开 systemd。
if [ "$(ps -p 1 -o comm= 2>/dev/null)" != systemd ]; then
  if [ ! -f /etc/wsl.conf ]; then
    printf '[boot]\nsystemd=true\n' > /etc/wsl.conf
  elif grep -q '^systemd=' /etc/wsl.conf; then
    sed -i 's/^systemd=.*/systemd=true/' /etc/wsl.conf
  elif grep -q '^\[boot\]' /etc/wsl.conf; then
    sed -i '/^\[boot\]/a systemd=true' /etc/wsl.conf
  else
    printf '\n[boot]\nsystemd=true\n' >> /etc/wsl.conf
  fi
  echo "NEED_WSL_RESTART"
  exit 3
fi

# ---------- 1) 目标用户 ----------
uid_of() { id -u "$1" 2>/dev/null; }
first_user() {
  # 取第一个 1000<=uid<65534 的普通用户（不依赖 awk，Fedora/Oracle 最小镜像没有 awk）
  while IFS=: read -r name _pass uid _gid _gecos home shell; do
    [ "$name" = nobody ] && continue
    if [ "$uid" -ge 1000 ] && [ "$uid" -lt 65534 ]; then
      printf '%s\n' "$name"
      return 0
    fi
  done < /etc/passwd
}
conf_default_user() {
  [ -r /etc/wsl.conf ] || return 0
  sed -n '/^\[user\]/,/^\[/s/^default=//p' /etc/wsl.conf | head -n1
}

CREATED_USER=0
if [ -z "$USER_NAME" ]; then
  USER_NAME=$(conf_default_user)
  [ -n "$USER_NAME" ] && id "$USER_NAME" >/dev/null 2>&1 || USER_NAME=""
fi
[ -z "$USER_NAME" ] && USER_NAME=$(first_user)
if [ -z "$USER_NAME" ] || [ "$USER_NAME" = root ]; then
  USER_NAME=u
fi

if ! id "$USER_NAME" >/dev/null 2>&1; then
  say "创建普通用户 $USER_NAME（GNOME 不能以 root 运行）"
  if getent passwd 1000 >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$USER_NAME"
  else
    useradd -m -u 1000 -s /bin/bash "$USER_NAME"
  fi
  CREATED_USER=1
fi

USER_UID=$(uid_of "$USER_NAME")
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)

# 让创建出来的用户能用 sudo（系统镜像里可能连 sudo 都没装，装包阶段补）
if [ "$CREATED_USER" = 1 ]; then
  install -d -m 0755 /etc/sudoers.d
  echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-wsl-desktop-$USER_NAME"
  chmod 0440 "/etc/sudoers.d/90-wsl-desktop-$USER_NAME"
fi
# 默认用户写进 wsl.conf：这样 wsl -d <发行版> 打开就是普通用户，不用 -u
if ! sed -n '/^\[user\]/,/^\[/p' /etc/wsl.conf 2>/dev/null | grep -q '^default='; then
  if grep -q '^\[user\]' /etc/wsl.conf 2>/dev/null; then
    sed -i "/^\[user\]/a default=$USER_NAME" /etc/wsl.conf
  else
    printf '\n[user]\ndefault=%s\n' "$USER_NAME" >> /etc/wsl.conf
  fi
fi
say "目标用户：$USER_NAME (uid=$USER_UID, home=$USER_HOME)"

# 用户管理器（systemd --user）设为开机常驻，剪贴板桥/音频桥不依赖登录会话
command -v loginctl >/dev/null 2>&1 && loginctl enable-linger "$USER_NAME" >/dev/null 2>&1 || true

# 用户级 systemd 单元（在 WSL 的 PAM 会话里才能连上用户总线）
user_systemctl() {
  su - "$USER_NAME" -c "export XDG_RUNTIME_DIR=/run/user/$USER_UID; systemctl --user $*" 2>/dev/null
}

# ---------- 2) 安装桌面组件 ----------
install_apt() {
  export DEBIAN_FRONTEND=noninteractive
  say "刷新 apt 索引…"
  apt-get update -qq || warn "apt-get update 有报错（继续尝试安装）"
  local desktop
  if apt-cache show ubuntu-desktop >/dev/null 2>&1; then
    desktop="ubuntu-desktop"
  elif apt-cache show kali-desktop-gnome >/dev/null 2>&1; then
    # Kali 的 kali-desktop-gnome 会拖进 300+ 个包（菜单/主题/工具），
    # 我们只需要一个能跑的 GNOME，所以装最小集合（实测 GNOME 50 + devkit 可用）
    desktop="gnome-shell gnome-session gnome-settings-daemon gnome-control-center nautilus gnome-terminal gnome-text-editor"
  else
    desktop="gnome-shell gnome-session gnome-control-center nautilus gnome-terminal"
  fi
  local extra="pulseaudio-utils python3"
  for pp in pipewire-pulse pipewire-pulseaudio; do
    apt-cache show "$pp" >/dev/null 2>&1 && { extra="$extra $pp"; break; }
  done
  apt-cache show wl-clipboard >/dev/null 2>&1 && extra="$extra wl-clipboard"
  apt-cache show x11-utils >/dev/null 2>&1 && extra="$extra x11-utils"
  apt-cache show mutter-dev-bin >/dev/null 2>&1 && extra="$extra mutter-dev-bin"
  say "安装 $desktop（首次会下载 1~3 GB）…"
  apt-get install -y -o Acquire::Retries=8 $desktop $extra || {
    warn "安装失败，重试一次（--fix-missing）…"
    apt-get -o Acquire::Retries=8 -y --fix-missing install $desktop $extra
  }
}

have_dnf_pkg() { dnf -q list --available "$1" >/dev/null 2>&1 && dnf -q list --available "$1" 2>/dev/null | grep -q "^$1\."; }

install_dnf() {
  say "刷新 dnf 索引…"
  dnf -q makecache || warn "dnf makecache 有报错（继续尝试安装）"
  local base="gnome-session gnome-settings-daemon gnome-control-center nautilus"
  local term=""
  for t in ptyxis gnome-terminal gnome-console; do
    if have_dnf_pkg "$t"; then term="$t"; break; fi
  done
  local extra="pipewire pipewire-pulseaudio wireplumber pulseaudio-utils xorg-x11-server-Xwayland"
  have_dnf_pkg wl-clipboard && extra="$extra wl-clipboard"
  have_dnf_pkg google-noto-sans-fonts && extra="$extra google-noto-sans-fonts google-noto-color-emoji-fonts"
  have_dnf_pkg sudo && extra="$extra sudo"

  if have_dnf_pkg mutter-devkit; then
    say "检测到 mutter-devkit（GNOME >= 49）：安装完整桌面"
    dnf install -y gnome-shell mutter-devkit $base $term $extra
  else
    # RHEL/Oracle：GNOME 47/48 支持 --nested，49 之后嵌套模式被 devkit 取代却没有打包 devkit。
    # 因此在没有 mutter-devkit 的发行版上固定 GNOME 47（Oracle Linux 10 的 appstream 同时提供 47/49）。
    if dnf -q repoquery --available 'gnome-shell-47*' 2>/dev/null | grep -q '^gnome-shell'; then
      say "没有 mutter-devkit，改用 GNOME 47 + 嵌套鸟（nested）模式"
      dnf install -y 'gnome-shell-47.*' 'mutter-47.*' $base $term $extra
    else
      say "安装 GNOME（没有 mutter-devkit，将尝试 --nested）"
      dnf install -y gnome-shell mutter $base $term $extra
    fi
  fi
}

if [ "$SKIP_PACKAGES" = 0 ]; then
  if command -v apt-get >/dev/null 2>&1; then
    install_apt
  elif command -v dnf >/dev/null 2>&1; then
    install_dnf
  else
    echo "不支持的发行版（既没有 apt-get 也没有 dnf）：$DISTRO_PRETTY" >&2
    exit 1
  fi
else
  say "跳过软件包安装（--skip-packages）"
fi

# 补一个终端（个别最小镜像不装桌面终端）
if [ -z "$(command -v gnome-terminal || command -v ptyxis || command -v kgx || command -v xterm)" ]; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y gnome-terminal >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ptyxis >/dev/null 2>&1 || dnf install -y xterm >/dev/null 2>&1 || true
  fi
fi

# ---------- 3) 音频 + 剪贴板 ----------
say "配置音频（WSLg PulseServer ⇄ PipeWire）…"
TARGET_USER="$USER_NAME" bash "$SRC/audio/install-audio.sh" || warn "音频配置有报错（见上）"
say "配置剪贴板同步…"
TARGET_USER="$USER_NAME" bash "$SRC/clipboard/install-clipbridge.sh" || warn "剪贴板配置有报错（见上）"

# PipeWire：mutter/devkit 启动时需要连接 pipewire，否则 GNOME Shell 会直接退出
user_systemctl "start pipewire.socket pipewire.service wireplumber.service" || true
user_systemctl "enable pipewire.socket wireplumber.service" || true

# 剪贴板桥用户服务
user_systemctl "daemon-reload" || true
user_systemctl "enable wsl-clipbridge.service" || true
user_systemctl "restart wsl-clipbridge.service" || true

# ---------- 4) 结果 ----------
if [ -x /usr/libexec/mutter-devkit ] && gnome-shell --help 2>/dev/null | grep -q -- '--devkit'; then
  MODE="devkit"
elif gnome-shell --help 2>/dev/null | grep -q -- '--nested'; then
  MODE="nested"
else
  MODE="unknown"
fi
echo
say "安装完成：$DISTRO_PRETTY"
say "  桌面模式：$MODE（devkit = GNOME 49+；nested = GNOME 47/48）"
say "  启动方式：wsl -d $WSL_DISTRO -u $USER_NAME -- bash -lc '~/start-desktop.sh'"
say "  首次启动后窗口标题一般会显示为「Mutter Development Kit ($WSL_DISTRO)」或「GNOME Shell」"
[ "$MODE" = unknown ] && warn "当前 GNOME 版本两种模式都不支持，请把上面的 --help 输出反馈给作者"
# 给 oneclick/install.ps1 解析用（不要在别处删掉）
echo "WSL_DESKTOP_USER=$USER_NAME"
echo "WSL_DESKTOP_MODE=$MODE"
echo "WSL_DESKTOP_DISTRO=$WSL_DISTRO"
exit 0
