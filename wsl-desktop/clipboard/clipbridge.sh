#!/usr/bin/env bash
# 双向文本剪贴板桥：内层 GNOME（Wayland）⇄ Windows 剪贴板
#
# 不再经过 WSLg 的 RDP 剪贴板通道（那一层经常卡死，还会把 Weston 日志刷爆），
# 改为和 Windows 侧常驻代理 clip-agent.ps1 通过固定目录交换文本文件：
#   /mnt/c/Users/Public/wsl-desktop-clip/win.txt         Windows 剪贴板快照
#   /mnt/c/Users/Public/wsl-desktop-clip/linux.req.txt   要求写入 Windows 剪贴板
#   /mnt/c/Users/Public/wsl-desktop-clip/agent.heartbeat 代理心跳（判断代理是否在跑）
#
# 代理由 ~/start-desktop.sh 自动拉起；本脚本由 systemd 用户服务 wsl-clipbridge 托管。
set -u

SHARE=${WSL_DESKTOP_CLIP_DIR:-/mnt/c/Users/Public/wsl-desktop-clip}
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
export WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}
LOG=${CLIPBRIDGE_LOG:-/tmp/clipbridge.log}
MAX_TEXT=1048576   # 单个文本剪贴板上限（1 MiB），超过就跳过，避免卡死

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >>"$LOG"; }

# 单实例
exec 9>/tmp/clipbridge.lock
if ! flock -n 9; then
  exit 0
fi

# 日志太大就截断
if [ -f "$LOG" ] && [ "$(wc -l <"$LOG" 2>/dev/null || echo 0)" -gt 300 ]; then
  tail -n 150 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
fi

# 找到内层 GNOME 的 Wayland socket：/run/user/<uid>/wayland-* 里最新的那个。
# （WSLg 自己的 wayland socket 在 /mnt/wslg/runtime-dir 下，不在这里；
#   内层 gnome-shell 起来时会新建 wayland-0/wayland-1，mtime 最新。）
find_inner_wd() {
  local f
  f=$(ls -t "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | grep -v '\.lock$' | head -n1)
  [ -n "$f" ] && basename "$f"
}

wl_get() {
  timeout 2 wl-paste -n -t text 2>/dev/null || true
}

wl_set() {
  printf '%s' "$1" | timeout 3 wl-copy 2>/dev/null
}

win_get() {
  local f="$SHARE/win.txt"
  [ -f "$f" ] || return 0
  local sz
  sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
  [ "$sz" -gt 0 ] && [ "$sz" -le "$MAX_TEXT" ] || return 0
  cat "$f" 2>/dev/null || true
}

win_put_req() {
  local t="$1" tmp="$SHARE/linux.req.tmp.$$"
  printf '%s' "$t" >"$tmp" 2>/dev/null || return 1
  mv -f "$tmp" "$SHARE/linux.req.txt" 2>/dev/null
}

log "启动: SHARE=$SHARE"

# 如果 GNOME Shell 剪贴板扩展已启用：同步完全在 shell 内部完成（不创建窗口、不抢焦点），
# 本服务只作为“状态检查用的 keepalive”，不再轮询 wl-paste
#（wl-clipboard 每次运行都会创建临时窗口 → Dock 把它当“未知应用”反复闪烁）。
EXT_UUID=clipbridge@wsl-desktop
if command -v gsettings >/dev/null 2>&1 && \
   gsettings get org.gnome.shell enabled-extensions 2>/dev/null | grep -q "$EXT_UUID"; then
  log "使用 GNOME Shell 扩展同步剪贴板（无 wl-paste 轮询、无窗口）"
  while :; do sleep 5; done
fi

wd=""
last_win=''
last_inner=''
seeded=0

while :; do
  # 内层桌面还没起来 / 代理还没创建目录时，等一等
  if [ -z "$wd" ] || [ ! -S "$XDG_RUNTIME_DIR/$wd" ]; then
    wd=$(find_inner_wd)
    [ -z "$wd" ] && { sleep 1; continue; }
    export WAYLAND_DISPLAY="$wd"
    log "内层 Wayland: $wd"
    seeded=0
  fi
  if [ ! -d "$SHARE" ]; then
    sleep 1
    continue
  fi

  # 首次连上：把当前 Windows 剪贴板灌进内层，之后只在“内容变化”时同步，
  # 避免 clobber 内层已有内容 / 避免来回抖动。
  if [ "$seeded" -eq 0 ]; then
    w=$(win_get)
    inner=$(wl_get)
    if [ -n "$w" ] && [ "$w" != "$inner" ]; then
      if wl_set "$w"; then
        log "初始同步 Windows -> 内层 (${#w} 字符)"
        last_inner=$w
      fi
    else
      last_inner=$inner
    fi
    last_win=$w
    seeded=1
  fi

  # Windows -> 内层（用缓存的 last_inner 比较，少调一次 wl-paste；写失败会重试）
  w=$(win_get)
  if [ "$w" != "$last_win" ]; then
    if [ -z "$w" ] || [ "$w" = "$last_inner" ]; then
      last_win=$w
    elif wl_set "$w"; then
      last_win=$w
      last_inner=$w
      log "Windows -> 内层 (${#w} 字符)"
    else
      log "写入内层失败，稍后重试"
    fi
  fi

  # 内层 -> Windows
  inner=$(wl_get)
  if [ -n "$inner" ] && [ "$inner" != "$last_inner" ]; then
    if [ "${#inner}" -le "$MAX_TEXT" ]; then
      if win_put_req "$inner"; then
        last_inner=$inner
        log "内层 -> Windows (${#inner} 字符)"
      fi
    else
      last_inner=$inner
      log "跳过超长剪贴板 (${#inner} 字符)"
    fi
  fi

  # wl-paste（wl-clipboard）每次运行都会创建一个临时窗口（标题 "wl-clipboard"），
  # GNOME Dock 会把它当成“未知应用”显示成齿轮图标；轮询太勤就会不停闪烁。
  # start-desktop.sh 已关闭 Dock 的“运行中程序”图标，这里也把轮询放宽到 0.5 秒。
  sleep 0.5
done
