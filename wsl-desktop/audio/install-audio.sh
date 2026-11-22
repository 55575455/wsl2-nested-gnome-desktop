#!/usr/bin/env bash
# 在 WSL 里以 root 运行：配置嵌套桌面的音频环境（适用于任意普通用户名、任意发行版）
#   - 有 mutter-devkit 时：gnome-shell override（--devkit）+ mutter-devkit 包装脚本
#   - wslg-pulse-bind 常驻守护：把 WSLg PulseServer bind mount 到 $XDG_RUNTIME_DIR/pulse/native
#   - ~/.config/environment.d/pulse.conf
#   - ~/start-desktop.sh / ~/stop-desktop.sh
#
# 支持 Ubuntu / Kali / Debian（apt）、Fedora / Oracle Linux / RHEL（dnf）
set -eu

# 目标用户：优先环境变量/SUDO_USER，否则取第一个 UID 1000~65533 的普通用户
TARGET_USER="${TARGET_USER:-${SUDO_USER:-}}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = root ]; then
  TARGET_USER=""
  while IFS=: read -r name _pass uid _gid _gecos _home _shell; do
    [ "$name" = nobody ] && continue
    if [ "$uid" -ge 1000 ] && [ "$uid" -lt 65534 ]; then
      TARGET_USER="$name"
      break
    fi
  done < /etc/passwd
fi
[ -n "$TARGET_USER" ] || { echo "找不到普通用户，请设置 TARGET_USER=用户名 再运行"; exit 1; }
TARGET_UID=$(id -u "$TARGET_USER")
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
echo "目标用户: $TARGET_USER (uid=$TARGET_UID, home=$TARGET_HOME)"
SRC="$(cd "$(dirname "$0")/.." && pwd)"

have_devkit() {
  [ -x /usr/libexec/mutter-devkit ] &&
    command -v gnome-shell >/dev/null 2>&1 &&
    gnome-shell --help 2>/dev/null | grep -q -- '--devkit'
}

# 1) gnome-shell 的启动参数与音频环境（仅 GNOME >= 49，有 mutter-devkit 的发行版）
#
# ⚠️ 这里**不要**设置 GDK_BACKEND=x11（TROUBLESHOOTING 4.9）：
#    gnome-shell 启动的应用会继承它的环境变量；一旦 shell 带 GDK_BACKEND=x11，
#    这些 GTK 应用就会连到 WSLg 的 X11 :0，窗口跑到桌面窗口外面，
#    变成 Windows 上单独的窗口（如「计算器 (Ubuntu)」「软件更新器 (Ubuntu)」）。
#    桌面窗口（mutter-devkit）的 X11 由 1.1) 的包装脚本单独负责。
if have_devkit; then
  install -d -m 0755 /etc/systemd/user/org.gnome.Shell@.service.d
  cat > /etc/systemd/user/org.gnome.Shell@.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/gnome-shell --devkit --no-x11 --wayland-display=wayland-1 --mode=%i
Environment=DISPLAY=:0
Environment=WAYLAND_DISPLAY=wayland-1
Environment=PULSE_SERVER=unix:/mnt/wslg/PulseServer
EOF

  # 1.1) mutter-devkit 包装脚本：桌面窗口走 X11，gnome-shell 启动的应用走嵌套 Wayland
  #      发行版升级 mutter 会把 /usr/libexec/mutter-devkit 还原成原版，所以每次安装都检查。
  if [ -x /usr/libexec/mutter-devkit ] && ! grep -q 'wsl-desktop' /usr/libexec/mutter-devkit 2>/dev/null; then
    mv -f /usr/libexec/mutter-devkit /usr/libexec/mutter-devkit.real
  fi
  install -m 0755 "$SRC/audio/mutter-devkit-wrapper.sh" /usr/libexec/mutter-devkit
  sed -i 's/\r$//' /usr/libexec/mutter-devkit
  echo "已配置 devkit 模式（GNOME >= 49）"
else
  echo "没有 mutter-devkit：使用 nested 模式（start-desktop.sh 启动时处理，不需要 shell override）"
  rm -f /etc/systemd/user/org.gnome.Shell@.service.d/override.conf 2>/dev/null || true
fi

# 2) bind mount 守护：把 WSLg PulseServer 挂到会话的 pulse socket 位置
cat > /usr/local/bin/wslg-pulse-bind <<'EOF'
#!/usr/bin/env bash
# 常驻守护：等 WSLg 音频 socket 和用户会话 runtime dir 就绪后，
# 把 WSLg PulseServer bind mount 到 $XDG_RUNTIME_DIR/pulse/native
# （snap 版 Firefox/Thunderbird 的 PULSE_SERVER 固定指向该路径）。
# PulseAudio 重启后 socket 会重建，这里检测 inode 变化自动重挂。
set -u
TARGET_UID=""
while IFS=: read -r _name _pass uid _gid _gecos _home _shell; do
  [ "$_name" = nobody ] && continue
  if [ "$uid" -ge 1000 ] && [ "$uid" -lt 65534 ]; then
    TARGET_UID="$uid"
    break
  fi
done < /etc/passwd
if [ -z "${TARGET_UID:-}" ] || ! id -nu "$TARGET_UID" >/dev/null 2>&1; then
  exit 0
fi
TARGET_USER=$(id -nu "$TARGET_UID")
RUNTIME="/run/user/$TARGET_UID"
TARGET="$RUNTIME/pulse/native"
SOURCE=/mnt/wslg/PulseServer
ensure() {
  [ -S "$SOURCE" ] || return 0
  [ -S "$RUNTIME/bus" ] || return 0
  mkdir -p "$RUNTIME/pulse"
  if mountpoint -q "$TARGET" 2>/dev/null; then
    if [ "$TARGET" -ef "$SOURCE" ]; then
      return 0
    fi
    umount "$TARGET" 2>/dev/null || true
  fi
  rm -f "$TARGET"
  touch "$TARGET"
  chown "$TARGET_USER:$TARGET_USER" "$TARGET"
  mount --bind "$SOURCE" "$TARGET" 2>/dev/null || true
}
while :; do
  ensure
  sleep 3
done
EOF
chmod 0755 /usr/local/bin/wslg-pulse-bind

cat > /etc/systemd/system/wslg-pulse-bind.service <<'EOF'
[Unit]
Description=Bind-mount WSLg PulseServer into session PulseAudio socket
After=local-fs.target

[Service]
Type=simple
ExecStart=/usr/local/bin/wslg-pulse-bind
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable wslg-pulse-bind.service >/dev/null 2>&1 || true
systemctl restart wslg-pulse-bind.service

# 3) 会话环境：让 dbus 激活的应用也能拿到 PULSE_SERVER
install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/.config/environment.d"
printf 'PULSE_SERVER=unix:/mnt/wslg/PulseServer\n' > "$TARGET_HOME/.config/environment.d/pulse.conf"
chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.config/environment.d/pulse.conf"

# 4) 启动 / 停止脚本
install -m 0755 "$SRC/clipboard/start-desktop.sh" "$TARGET_HOME/start-desktop.sh"
install -m 0755 "$SRC/audio/stop-desktop.sh" "$TARGET_HOME/stop-desktop.sh"
# 从 Windows 仓库复制过来时可能带 CRLF，统一去掉（否则 shebang 会变成 bash\r，脚本起不来）
sed -i 's/\r$//' "$TARGET_HOME/start-desktop.sh" "$TARGET_HOME/stop-desktop.sh"
chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/start-desktop.sh" "$TARGET_HOME/stop-desktop.sh"

echo "=== 音频环境安装完成 ==="
systemctl --no-pager status wslg-pulse-bind.service 2>&1 | head -6 || true
mountpoint "/run/user/$TARGET_UID/pulse/native" 2>&1 || true
ls -l "/run/user/$TARGET_UID/pulse/native" 2>&1 || true
