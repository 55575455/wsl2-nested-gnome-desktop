#!/usr/bin/env bash
# 启动嵌套 GNOME 桌面会话，并保证「声音 + 剪贴板」一起就绪。
#
# 默认是「后台启动」：脚本把桌面交给 systemd 用户单元托管后立即返回，
# **不会占用当前终端**（以前直接 exec gnome-session 会把终端吃掉）。
#
# 启动时自动做这些事：
#   1) WSLg 音频服务卡死（设置里显示“无输出设备”）→ 自动热重启 WSLg 的 PulseAudio；
#   2) 启动 Windows 侧剪贴板代理 clip-agent.ps1（双向文本剪贴板 + 音频看门狗）；
#   3) 启动内层 ⇄ Windows 的剪贴板桥 wsl-clipbridge；
#   4) 清理上次没退干净的会话，避免 “A graphical session is already running!”；
#   5) 关掉系统提示音（在本机 WSLg 上，提示音是音频卡死的常见触发器）；
#   6) 修复“应用窗口跑到 Ubuntu 桌面窗口外面”的配置（gnome-shell 不强制 GDK_BACKEND=x11，
#      mutter-devkit 单独走 X11；apt 升级后也能自愈，见 TROUBLESHOOTING 4.9）。
#
# 用法：
#   ~/start-desktop.sh                # 后台启动（终端立即释放）
#   ~/start-desktop.sh --check        # 查看状态（会话/声音/剪贴板）
#   ~/start-desktop.sh --fix          # 只修复声音/剪贴板（不启动桌面）
#   ~/start-desktop.sh --stop         # 停止桌面
#   ~/start-desktop.sh --foreground   # 前台启动（占用终端，调试/排障用）
#
# 说明：桌面已经在运行时，以上命令都不会重复启动，只做检查/修复。
#       用 systemd-run 启动（例如
#         systemd-run --user --unit=wsl-desktop-session --collect ~/start-desktop.sh）
#       也完全兼容：检测到已在 systemd 单元里就不再套一层。
#
# 可重复执行（幂等）：桌面已运行只做检查/修复；关掉窗口后残留的 unit 会自动清理再启动。
# 注意：不要反复手动执行 systemd-run 同一个单元名——单元已存在时它会报
#   “Unit wsl-desktop-session.service was already loaded or has a fragment file”，
# 这是正常的（说明桌面单元已存在，不是错误），改用本脚本即可（脚本会自动清理残留单元）。
set -uo pipefail

UNIT=wsl-desktop-session
TARGETS=('gnome-session@ubuntu.target' 'gnome-session-manager.target' 'gnome-session-basic-services.target' 'gnome-session-services.target')
SHARE=${WSL_DESKTOP_CLIP_DIR:-/mnt/c/Users/Public/wsl-desktop-clip}
AGENT_SRC=/usr/local/lib/wsl-desktop/clip-agent.ps1
PS_EXE=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
WSL_EXE=/mnt/c/Windows/System32/wsl.exe
MUTTER_DEVKIT=/usr/libexec/mutter-devkit
SHELL_OVERRIDE=/etc/systemd/user/org.gnome.Shell@.service.d/override.conf
WRAPPER_TMP=/tmp/wsl-desktop-mutter-devkit
OVERRIDE_TMP=/tmp/wsl-desktop-shell-override.conf
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"
export PULSE_SERVER="${PULSE_SERVER:-unix:/mnt/wslg/PulseServer}"
export WSL_DISTRO_NAME="${WSL_DISTRO_NAME:-Ubuntu}"
# 用 systemd-run 启动时环境里可能没有 WSL_INTEROP，这里补上，Windows 互操作才可用
if [ -z "${WSL_INTEROP:-}" ]; then
  for f in /run/WSL/1_interop /run/WSL/2_interop /run/WSL/*_interop; do
    [ -S "$f" ] && { export WSL_INTEROP="$f"; break; }
  done
fi

has_shell() { pgrep -x gnome-shell >/dev/null 2>&1; }
session_alive() {
  gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
    --method org.freedesktop.DBus.NameHasOwner org.gnome.SessionManager 2>/dev/null | grep -q '(true'
}

usage() {
  cat <<'USAGE'
用法：
  ~/start-desktop.sh               后台启动桌面（立即返回，不占用终端）
  ~/start-desktop.sh --check       查看状态（会话/声音/剪贴板）
  ~/start-desktop.sh --fix         只修复声音/剪贴板（不启动桌面）
  ~/start-desktop.sh --stop        停止桌面
  ~/start-desktop.sh --foreground  前台启动（占用终端，调试/排障用）

说明：桌面已在运行时不会重复启动，只做检查/修复；可放心重复执行（幂等）。
      关掉窗口后残留的桌面单元会自动清理再启动。
      systemd-run 启动方式依然兼容（但单元已存在时会报 already loaded，属正常）：
        systemd-run --user --unit=wsl-desktop-session --collect ~/start-desktop.sh
USAGE
}

# ---------- 声音 ----------
audio_ok() { LC_ALL=C timeout 6 pactl -s unix:/mnt/wslg/PulseServer info 2>/dev/null | grep -q '^Default Sink: '; }
audio_sink() { LC_ALL=C timeout 6 pactl -s unix:/mnt/wslg/PulseServer info 2>/dev/null | sed -n 's/^Default Sink: //p' | head -n1; }
pulse_socket_ok() { [ -e "$XDG_RUNTIME_DIR/pulse/native" ] && [ "$XDG_RUNTIME_DIR/pulse/native" -ef /mnt/wslg/PulseServer ] 2>/dev/null; }

ensure_pulse_socket() {
  pulse_socket_ok && return 0
  for _ in $(seq 1 12); do            # wslg-pulse-bind 守护会自动重挂 socket
    pulse_socket_ok && return 0
    sleep 1
  done
  echo "[警告] $XDG_RUNTIME_DIR/pulse/native 没挂到 WSLg 的 PulseServer（snap 应用可能没声音）" >&2
  echo "       可运行：sudo systemctl restart wslg-pulse-bind" >&2
  return 1
}

ensure_audio() {
  if audio_ok; then return 0; fi
  echo "检测到 WSLg 音频服务卡死（设置里会显示“无输出设备”），正在热重启音频…"
  pkill -f gnome-control-center 2>/dev/null || true      # 声音设置面板是卡死触发器，先关掉
  if [ -x "$WSL_EXE" ]; then
    ( cd /mnt/c 2>/dev/null && timeout 20 "$WSL_EXE" --system -- sh -c 'pkill -9 pulseaudio' >/dev/null 2>&1 ) || true
  fi
  for _ in $(seq 1 15); do
    if audio_ok; then
      sleep 1
      echo "音频已恢复，默认输出：$(audio_sink)"
      return 0
    fi
    sleep 1
  done
  echo "[警告] 音频热重启失败。请在 Windows 里运行 oneclick/fix-audio.ps1，或 wsl --shutdown 后重新启动桌面。" >&2
  return 1
}

# ---------- 剪贴板 ----------
agent_alive() {
  local hb="$SHARE/agent.heartbeat" age
  [ -f "$hb" ] || return 1
  age=$(( $(date +%s) - $(stat -c %Y "$hb" 2>/dev/null || echo 0) ))
  [ "$age" -lt 20 ]
}

ensure_clip_agent() {
  mkdir -p "$SHARE" 2>/dev/null || true
  [ -f "$AGENT_SRC" ] && cp -f "$AGENT_SRC" "$SHARE/clip-agent.ps1" 2>/dev/null || true
  agent_alive && return 0
  if [ ! -x "$PS_EXE" ]; then
    echo "[警告] 找不到 Windows PowerShell，剪贴板代理无法启动" >&2
    return 1
  fi
  ( cd /mnt/c 2>/dev/null || cd /mnt/wslg || cd /
    setsid "$PS_EXE" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden \
      -File 'C:\Users\Public\wsl-desktop-clip\clip-agent.ps1' \
      -Distro "$WSL_DISTRO_NAME" </dev/null >/dev/null 2>&1 & )
  for _ in $(seq 1 40); do
    agent_alive && return 0
    sleep 0.5
  done
  echo "[警告] 剪贴板代理启动失败，可用 ~/start-desktop.sh --check 查看" >&2
  return 1
}

ensure_clipbridge() {
  systemctl --user restart wsl-clipbridge 2>/dev/null || true
  for _ in $(seq 1 8); do
    systemctl --user is-active wsl-clipbridge >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  echo "[警告] 剪贴板桥 wsl-clipbridge 没启动，可用 journalctl --user -u wsl-clipbridge 查看" >&2
  return 1
}

# ---------- 让应用窗口留在「Ubuntu 桌面」里面（不跑到 Windows 外层） ----------
# 原因（TROUBLESHOOTING 4.9）：gnome-shell 的 systemd override 里如果带 GDK_BACKEND=x11，
# 它启动的所有 GTK 应用都会继承这个变量 → 连到 WSLg 的 X11 :0 → 变成 Windows 上单独的窗口
# （任务栏里能看到「软件更新器 (Ubuntu)」「计算器 (Ubuntu)」这类窗口）。
# 正确配置：
#   1) shell override 不带 GDK_BACKEND，只留 DISPLAY=:0 + WAYLAND_DISPLAY=wayland-0；
#   2) mutter-devkit（负责“桌面窗口”）用包装脚本单独强制 X11。
# apt 升级 mutter-dev-bin 会把 /usr/libexec/mutter-devkit 还原成原版，所以每次启动都检查并自愈。
nested_windows_ok() {
  [ -x "$MUTTER_DEVKIT" ] && grep -q 'wsl-desktop' "$MUTTER_DEVKIT" 2>/dev/null &&
    [ -x "$MUTTER_DEVKIT.real" ] &&
    [ -r "$SHELL_OVERRIDE" ] &&
    grep -q '^Environment=WAYLAND_DISPLAY=wayland-0' "$SHELL_OVERRIDE" 2>/dev/null &&
    ! grep -q '^Environment=GDK_BACKEND' "$SHELL_OVERRIDE" 2>/dev/null
}

write_nested_backend_files() {
  cat > "$WRAPPER_TMP" <<'EOF'
#!/bin/sh
# wsl-desktop: 桌面窗口（mutter-devkit）必须走 X11（WSLg Xwayland :0）；
# gnome-shell 主进程不带 GDK_BACKEND，这样它启动的应用才会走嵌套 Wayland 桌面。
GDK_BACKEND=x11
DISPLAY=:0
export GDK_BACKEND DISPLAY
exec /usr/libexec/mutter-devkit.real "$@"
EOF
  cat > "$OVERRIDE_TMP" <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/gnome-shell --devkit --no-x11 --mode=%i
Environment=DISPLAY=:0
Environment=WAYLAND_DISPLAY=wayland-0
Environment=PULSE_SERVER=unix:/mnt/wslg/PulseServer
EOF
}

ensure_nested_windows() {
  local marker=WSL_DESKTOP_BACKEND_OK
  nested_windows_ok && return 0
  write_nested_backend_files
  if [ -x "$WSL_EXE" ] && ( cd /mnt/c 2>/dev/null || cd /
       timeout 30 "$WSL_EXE" -d "${WSL_DISTRO_NAME:-Ubuntu}" -u root -- bash -lc \
         "grep -q 'wsl-desktop' '$MUTTER_DEVKIT' 2>/dev/null || { [ -x '$MUTTER_DEVKIT' ] && mv -f '$MUTTER_DEVKIT' '$MUTTER_DEVKIT.real'; }; [ -x '$MUTTER_DEVKIT.real' ] && install -m 0755 '$WRAPPER_TMP' '$MUTTER_DEVKIT'; install -d -m 0755 '$(dirname "$SHELL_OVERRIDE")'; install -m 0644 '$OVERRIDE_TMP' '$SHELL_OVERRIDE'; [ -x '$MUTTER_DEVKIT.real' ] && echo $marker" ) 2>/dev/null | grep -q "$marker"; then
    systemctl --user daemon-reload 2>/dev/null || true
    if nested_windows_ok; then
      echo "已修复「应用跑到桌面窗口外面」的配置（TROUBLESHOOTING 4.9）："
      echo "  - gnome-shell 不再强制 GDK_BACKEND=x11（它启动的应用走嵌套 Wayland 桌面）"
      echo "  - mutter-devkit 单独走 X11（桌面窗口照常显示）"
      if has_shell; then
        echo "  重启桌面后生效：~/start-desktop.sh --stop && ~/start-desktop.sh"
      fi
      return 0
    fi
  fi
  echo "[提示] 没能自动修复「应用跑到桌面窗口外面」的配置（需要 WSL root，或 mutter-dev-bin 被卸载）。" >&2
  echo "       重新运行 oneclick\\install.ps1 -SkipApt -NoStart 即可修复；" >&2
  echo "       若 mutter-devkit 原版丢失：wsl -d Ubuntu -u root -- bash -lc 'apt-get install --reinstall -y mutter-dev-bin'" >&2
  return 1
}

run_ensure() {
  ensure_nested_windows || true
  ensure_desktop_tweaks || true
  ensure_pulse_socket || true
  ensure_audio || true
  ensure_clip_agent || true
  ensure_clipbridge || true
}

# ---------- 桌面小调整（防闪烁） ----------
# 1) 嵌套 --no-x11 会话里，gnome-shell 的 systemd override 会带 GDK_BACKEND=x11
#（mutter-devkit 窗口需要），桌面图标扩展 ding 继承后以 X11Wayland 运行，
# 反复重建桌面窗口并弹出「Desktop Icons NG 正在 X11Wayland 下运行」警告、任务栏图标闪烁。
# 这里默认禁用 ding（嵌套桌面不需要桌面图标；需要时 gnome-extensions enable ding@rastersoft.com）。
# 2) 剪贴板桥每隔 0.5 秒运行一次 wl-paste，而 wl-clipboard 每次都会创建一个临时窗口
#（"wl-clipboard"），Dock 把它当“未知应用”显示成齿轮图标 → 反复闪。
# 关掉 Dock 的“运行中程序”图标即可（固定收藏的图标不受影响，剪贴板照常工作）。
ensure_desktop_tweaks() {
  command -v gsettings >/dev/null 2>&1 || return 0

  # 1) 桌面图标扩展 ding：嵌套 --no-x11 会话里以 X11Wayland 运行，会反复重建桌面窗口
  #    并弹出「Desktop Icons NG 正在 X11Wayland 下运行」警告（TROUBLESHOOTING 4.7）。
  gsettings set org.gnome.shell.extensions.ding check-x11wayland false 2>/dev/null || true
  python3 - <<'PY' 2>/dev/null || true
import ast, subprocess
def get(key):
    out = subprocess.run(['gsettings', 'get', 'org.gnome.shell', key],
                         capture_output=True, text=True).stdout.strip()
    try:
        return ast.literal_eval(out)
    except Exception:
        return []
lst = get('disabled-extensions')
if 'ding@rastersoft.com' not in lst:
    lst.append('ding@rastersoft.com')
    subprocess.run(['gsettings', 'set', 'org.gnome.shell', 'disabled-extensions',
                    '[' + ', '.join(repr(x) for x in lst) + ']'], check=False)
PY

  # 2) 剪贴板桥改用 GNOME Shell 扩展：在 shell 内部直接读/写剪贴板，不再每 0.2 秒
  #    运行 wl-paste（wl-clipboard 每次都会创建临时窗口，Dock 会把它当“未知应用”
  #    刷出齿轮图标、还会抢焦点，TROUBLESHOOTING 4.8）。这里启用扩展。
  python3 - <<'PY' 2>/dev/null || true
import ast, subprocess
def get(key):
    out = subprocess.run(['gsettings', 'get', 'org.gnome.shell', key],
                         capture_output=True, text=True).stdout.strip()
    try:
        return ast.literal_eval(out)
    except Exception:
        return []
lst = get('enabled-extensions')
if 'clipbridge@wsl-desktop' not in lst:
    lst.append('clipbridge@wsl-desktop')
    subprocess.run(['gsettings', 'set', 'org.gnome.shell', 'enabled-extensions',
                    '[' + ', '.join(repr(x) for x in lst) + ']'], check=False)
PY

  # 2.1) gnome-shell 崩溃后，GNOME 会启动 org.gnome.Shell-disable-extensions.service，
  #      把 org.gnome.shell disable-user-extensions 设成 true → 剪贴板扩展也被禁用，
  #      表现就是“复制粘贴突然挂了”（代理和桥都正常，见 TROUBLESHOOTING 6 ④）。
  #      这里每次启动/--fix 都恢复；桌面在跑时顺便立即启用扩展。
  gsettings set org.gnome.shell disable-user-extensions false 2>/dev/null || true
  rm -f "$XDG_RUNTIME_DIR/gnome-shell-disable-extensions" 2>/dev/null || true
  if has_shell; then
    gnome-extensions list --enabled 2>/dev/null | grep -qx 'clipbridge@wsl-desktop' ||
      gnome-extensions enable clipbridge@wsl-desktop 2>/dev/null || true
  fi

  # 3) 保留 Dock 的“运行中程序”图标（方便切换窗口）
  gsettings set org.gnome.shell.extensions.dash-to-dock show-running true 2>/dev/null || true
  return 0
}

print_short_status() {
  echo "声音：$(audio_ok && echo 正常 || echo 卡死)  默认输出：$(audio_sink || echo 无)"
  echo "剪贴板代理：$(agent_alive && echo 在跑 || echo 未运行)  剪贴板桥：$(systemctl --user is-active --quiet wsl-clipbridge 2>/dev/null && echo active || echo inactive)"
}

# ---------- 参数 ----------
MODE=auto
case "${1:-}" in
  ""|--background) MODE=auto ;;
  --check)         MODE=check ;;
  --fix)           MODE=fix ;;
  --stop)          MODE=stop ;;
  --foreground)    MODE=foreground ;;
  -h|--help)       usage; exit 0 ;;
  *)               echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
esac

# ---------- --check ----------
if [ "$MODE" = check ]; then
  shell_count=$(pgrep -c -x gnome-shell 2>/dev/null || true)
  echo "gnome-shell:            ${shell_count:-0} 个"
  echo "gnome-session target:   $(systemctl --user is-active --quiet 'gnome-session@ubuntu.target' 2>/dev/null && echo active || echo inactive)"
  echo "SessionManager DBus:    $(session_alive && echo 已占用 || echo 空闲)"
  echo "wsl-desktop-session:    $(systemctl --user is-active --quiet "$UNIT" 2>/dev/null && echo active || echo inactive)"
  if [ "${shell_count:-0}" -gt 0 ]; then
    session_state="正常（桌面在运行）"
  elif systemctl --user is-active --quiet "$UNIT" 2>/dev/null; then
    session_state="残留（unit 在跑但桌面已退出，运行 ~/start-desktop.sh 会自动清理并重启）"
  else
    session_state="未运行"
  fi
  echo "会话状态:               $session_state"
  echo "wayland socket:         $(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | grep -v '\.lock$' | head -n1 || echo 无)"
  echo "声音服务:               $(audio_ok && echo 正常 || echo 卡死)  默认输出: $(audio_sink || echo 无)"
  echo "pulse socket 挂载:      $(pulse_socket_ok && echo 已挂载 || echo 未挂载)"
  echo "剪贴板代理(Windows):    $(agent_alive && echo 在跑 || echo 未运行)"
  echo "剪贴板桥(服务):         $(systemctl --user is-active --quiet wsl-clipbridge 2>/dev/null && echo active || echo inactive)"
  echo "剪贴板交换目录:         $SHARE"
  echo "桌面图标扩展(ding):     $(gsettings get org.gnome.shell disabled-extensions 2>/dev/null | grep -q 'ding@rastersoft.com' && echo 已禁用（防闪烁） || echo 运行中)"
  echo "Dock 运行图标:          $(gsettings get org.gnome.shell.extensions.dash-to-dock show-running 2>/dev/null | grep -q true && echo 已开启（保留运行图标，方便切换） || echo 已关闭)"
  if nested_windows_ok; then
    echo "应用窗口归属:           在 Ubuntu 桌面窗口内（嵌套 Wayland）"
  else
    echo "应用窗口归属:           可能跑到 Windows 外层（跑一次 ~/start-desktop.sh 修复）"
  fi
  if ! has_shell; then
    echo "剪贴板同步:             桌面未运行（下次启动会自动启用扩展）"
  elif gnome-extensions list --enabled 2>/dev/null | grep -qx 'clipbridge@wsl-desktop'; then
    echo "剪贴板同步:             GNOME Shell 扩展（无窗口、不抢焦点）"
  elif gsettings get org.gnome.shell enabled-extensions 2>/dev/null | grep -q 'clipbridge@wsl-desktop'; then
    echo "剪贴板同步:             扩展被禁用（剪贴板不通；跑一次 ~/start-desktop.sh --fix 恢复）"
  else
    echo "剪贴板同步:             wl-paste 轮询（旧方式，会闪 Dock 图标）"
  fi
  exit 0
fi

# ---------- --stop ----------
if [ "$MODE" = stop ]; then
  if [ -x "$HOME/stop-desktop.sh" ]; then
    exec "$HOME/stop-desktop.sh"
  fi
  systemctl --user stop "$UNIT" 2>/dev/null || true
  pkill -x gnome-shell 2>/dev/null || true
  echo "已停止桌面。"
  exit 0
fi

# ---------- --fix ----------
if [ "$MODE" = fix ]; then
  run_ensure
  echo "修复完成（未启动/重启桌面）："
  print_short_status
  if ! has_shell && systemctl --user is-active --quiet "$UNIT" 2>/dev/null; then
    echo "提示：检测到残留的桌面单元（unit 在跑但桌面已退出）；运行 ~/start-desktop.sh 会自动清理并启动桌面。"
  fi
  exit 0
fi

# ---------- 后台启动（默认） ----------
# 已经在 systemd 单元里（systemd-run / install.ps1 的启动方式）或显式 --foreground
# 时，不再套一层；否则把桌面交给 systemd 用户单元，终端立即释放。
IN_UNIT=0
[ -n "${INVOCATION_ID:-}" ] && IN_UNIT=1
[ -n "${WSL_DESKTOP_IN_UNIT:-}" ] && IN_UNIT=1

if [ "$MODE" = auto ] && [ "$IN_UNIT" -eq 0 ]; then
  if has_shell; then
    :   # 桌面已在跑：走下面的修复 + 提示逻辑，不再重复启动
  else
    SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
    if command -v systemd-run >/dev/null 2>&1; then
      # 关掉窗口后残留的桌面单元（unit 还在，但 gnome-shell 已退出）→ 先清理再启动。
      # 不清理的话，systemd-run 会报 “Unit ... was already loaded or has a fragment file”。
      if systemctl --user is-active --quiet "$UNIT" 2>/dev/null; then
        echo "检测到残留的桌面单元（unit 还在，但桌面窗口已退出），正在清理…"
      fi
      systemctl --user stop "$UNIT" 2>/dev/null || true
      systemctl --user reset-failed "$UNIT" 2>/dev/null || true
      for _ in $(seq 1 20); do
        systemctl --user is-active --quiet "$UNIT" 2>/dev/null || break
        sleep 0.5
      done
      if systemd-run --user --unit="$UNIT" --collect \
           --setenv=WSL_DESKTOP_IN_UNIT=1 "$SELF" >/dev/null 2>&1; then
        echo "桌面已在后台启动（终端不会被占用）。"
        echo "  首次启动约需 10~20 秒，之后会弹出「Mutter Development Kit」窗口。"
        echo "  查看状态：~/start-desktop.sh --check    停止：~/start-desktop.sh --stop"
        echo "  需要前台看日志：~/start-desktop.sh --foreground"
        exit 0
      fi
      echo "[错误] systemd-run 后台启动失败（本脚本不会占用你的终端）。" >&2
      echo "       如果提示 “Unit ... was already loaded”：说明桌面单元已存在（可能在运行，或上次没退干净）。" >&2
      echo "       直接重新运行 ~/start-desktop.sh 即可（脚本会自动清理残留单元）；仍失败再：" >&2
      echo "         ~/start-desktop.sh --stop && ~/start-desktop.sh" >&2
      echo "       查看状态：~/start-desktop.sh --check    看前台日志：~/start-desktop.sh --foreground" >&2
      exit 1
    else
      echo "[错误] 系统里没有 systemd-run，无法后台启动（本脚本不会占用你的终端）。" >&2
      echo "       需要前台运行时请显式使用：~/start-desktop.sh --foreground" >&2
      exit 1
    fi
  fi
fi

# ---------- 0) 先确保声音 / 剪贴板可用（桌面是否已运行都做） ----------
run_ensure

# 1) 桌面完整在跑 → 不重复启动
if has_shell; then
  echo "桌面已经在运行（gnome-shell 在跑），无需重复启动。"
  print_short_status
  echo "（重复手动执行 systemd-run 同一单元会报 already loaded，这是正常的；本脚本可放心重复运行）"
  echo "如需重启：~/start-desktop.sh --stop && ~/start-desktop.sh"
  exit 0
fi

# 2) 有残留会话管理器 → 清理
if session_alive; then
  echo "检测到上次残留的 GNOME 会话（桌面窗口已关闭但会话没退干净），正在清理…"
  unit_mainpid=$(systemctl --user show -p MainPID --value "$UNIT" 2>/dev/null || echo 0)
  if [ -n "$unit_mainpid" ] && [ "$unit_mainpid" != "$$" ] && [ "$unit_mainpid" != "0" ]; then
    systemctl --user stop "$UNIT" 2>/dev/null || true
  fi
  if command -v gnome-session-quit >/dev/null 2>&1; then
    timeout 15 gnome-session-quit --logout --no-prompt >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
      session_alive || break
      sleep 1
    done
  fi
  systemctl --user stop "${TARGETS[@]}" 2>/dev/null || true
  systemctl --user stop 'gnome-session-manager@ubuntu.service' 'gnome-session-monitor.service' 'gnome-session-ctl.service' 2>/dev/null || true
  for n in gnome-session-service gnome-session-ctl gnome-session-init-worker gnome-session-binary \
           gnome-session-b gnome-shell gnome-shell-calendar-server mutter-devkit; do
    pkill -x "$n" 2>/dev/null || true
  done
  for _ in $(seq 1 10); do
    session_alive || break
    sleep 1
  done
  if session_alive; then
    echo "残留会话仍未退出，强制结束…"
    for n in gnome-session-service gnome-session-ctl gnome-session-init-worker gnome-session-binary gnome-session-b; do
      pkill -9 -x "$n" 2>/dev/null || true
    done
    sleep 2
  fi
  if session_alive; then
    echo "错误：残留会话管理器仍未退出，请运行 ~/start-desktop.sh --stop 后重试。" >&2
    exit 1
  fi
fi

# 3) 环境
systemctl --user import-environment DISPLAY WAYLAND_DISPLAY PULSE_SERVER 2>/dev/null || true
systemctl --user set-environment DISPLAY=:0 PULSE_SERVER="$PULSE_SERVER" 2>/dev/null || true
[ -n "${WSL_INTEROP:-}" ] && systemctl --user set-environment WSL_INTEROP="$WSL_INTEROP" 2>/dev/null || true
systemctl --user set-environment WSL_DISTRO_NAME="$WSL_DISTRO_NAME" 2>/dev/null || true
# 关掉系统提示音/启动音：本机 WSLg 在播放提示音后音频服务容易卡死
gsettings set org.gnome.desktop.sound event-sounds false 2>/dev/null || true
gsettings set org.gnome.desktop.sound input-feedback-sounds false 2>/dev/null || true

# 4) 启动
echo "即将启动桌面：声音=$(audio_ok && echo 正常 || echo 未知)  剪贴板代理=$(agent_alive && echo 在跑 || echo 未运行)  剪贴板桥=$(systemctl --user is-active --quiet wsl-clipbridge 2>/dev/null && echo active || echo inactive)"
extra=()
[ -n "${GALLIUM_DRIVER:-}" ] && extra+=("GALLIUM_DRIVER=$GALLIUM_DRIVER")
exec env XDG_CURRENT_DESKTOP=ubuntu:GNOME XDG_SESSION_TYPE=wayland "${extra[@]}" gnome-session
