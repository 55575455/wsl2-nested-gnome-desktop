#!/usr/bin/env bash
# 以普通用户运行：重启嵌套桌面会话（systemd 用户单元托管，关掉终端也不会退出）
set -uo pipefail
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"
export PULSE_SERVER="${PULSE_SERVER:-unix:/mnt/wslg/PulseServer}"
HOME_DIR="${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}"

echo "--- 停止旧会话 ---"
bash "$HOME_DIR/stop-desktop.sh" 2>/dev/null || {
  systemctl --user stop wsl-desktop-session 2>/dev/null || true
  systemctl --user stop 'gnome-session@ubuntu.target' 2>/dev/null || true
}
sleep 1

echo "--- 启动会话 ---"
systemd-run --user --unit=wsl-desktop-session --collect "$HOME_DIR/start-desktop.sh" 2>&1
sleep 15

echo "--- 状态 ---"
systemctl --user --no-pager status wsl-desktop-session 2>&1 | head -10
pgrep -af 'gnome-session|gnome-shell --devkit|mutter-devkit' | head -8 || true

echo "--- 音频（应能看到 RDPSink）---"
PULSE_SERVER="$PULSE_SERVER" LC_ALL=C timeout 8 pactl info 2>&1 | grep -E 'Server Name|Default Sink|Default Source'
PULSE_SERVER="$PULSE_SERVER" LC_ALL=C timeout 8 pactl list short sinks 2>&1
