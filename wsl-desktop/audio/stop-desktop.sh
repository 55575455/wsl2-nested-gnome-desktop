#!/usr/bin/env bash
# 停止嵌套 GNOME 桌面会话（含「窗口关了但会话管理器残留」的清理）。
# 剪贴板桥（wsl-clipbridge）和 WSLg 音频服务不受影响。
set -uo pipefail

UNIT=wsl-desktop-session
TARGETS=('gnome-session@ubuntu.target' 'gnome-session-manager.target' 'gnome-session-basic-services.target' 'gnome-session-services.target')
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1
log() { [ "$QUIET" = 1 ] || echo "$@"; }

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"

session_alive() {
  gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
    --method org.freedesktop.DBus.NameHasOwner org.gnome.SessionManager 2>/dev/null | grep -q '(true'
}

log "停止桌面会话…"

# 1) 停 systemd 单元（前提：本脚本不是该单元本身）
unit_mainpid=$(systemctl --user show -p MainPID --value "$UNIT" 2>/dev/null || echo 0)
if [ -n "$unit_mainpid" ] && [ "$unit_mainpid" != "$$" ] && [ "$unit_mainpid" != "0" ]; then
  systemctl --user stop "$UNIT" 2>/dev/null || true
fi

# 2) 优先走正常注销：让 gnome-session 自己退出并释放 org.gnome.SessionManager
if session_alive && command -v gnome-session-quit >/dev/null 2>&1; then
  log "（尝试 gnome-session-quit 正常注销…）"
  timeout 15 gnome-session-quit --logout --no-prompt >/dev/null 2>&1 || true
  for _ in $(seq 1 15); do
    session_alive || break
    sleep 1
  done
fi

# 3) 停 target / 服务
systemctl --user stop "${TARGETS[@]}" 2>/dev/null || true
systemctl --user stop \
  'gnome-session-manager@ubuntu.service' \
  'gnome-session-monitor.service' \
  'gnome-session-ctl.service' 2>/dev/null || true

# 4) 进程兜底
for n in gnome-session-service gnome-session-ctl gnome-session-init-worker gnome-session-binary \
         gnome-session-b gnome-shell gnome-shell-calendar-server mutter-devkit; do
  pkill -x "$n" 2>/dev/null || true
done

# 5) 等待 DBus 名释放，仍不释放则强杀
for _ in $(seq 1 10); do
  session_alive || break
  sleep 1
done
if session_alive; then
  log "仍有残留会话管理器，强制结束…"
  ps -eo pid,cmd | grep -E '[g]nome-session' | head -10 || true
  for n in gnome-session-service gnome-session-ctl gnome-session-init-worker gnome-session-binary gnome-session-b; do
    pkill -9 -x "$n" 2>/dev/null || true
  done
  sleep 1
fi

log "桌面会话已停止。"
exit 0
