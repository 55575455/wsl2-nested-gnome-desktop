#!/usr/bin/env bash
# 双向文本剪贴板自测（桌面在跑时，在 WSL 里以普通用户运行）
#
# 测试内容：
#   1) 剪贴板桥服务 + Windows 侧代理心跳
#   2) Linux → Windows（在桌面里 wl-copy，再从 Windows 剪贴板读回来）
#   3) Windows → Linux（用 Windows PowerShell 写入剪贴板，再在内层 wl-paste 读）
#
# 用法：
#   bash wsl-desktop/clipboard/final-clip-test.sh
set -u

export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
SHARE=${WSL_DESKTOP_CLIP_DIR:-/mnt/c/Users/Public/wsl-desktop-clip}
wd=$(ls -t "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | grep -v '\.lock$' | head -n1)
export WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-$(basename "$wd" 2>/dev/null)}

fail=0
echo "剪贴板交换目录: $SHARE"
echo "内层 Wayland:   ${WAYLAND_DISPLAY:-（未找到）}"
echo

echo "=== 1) 服务与代理状态 ==="
bridge=$(systemctl --user is-active wsl-clipbridge 2>/dev/null || true)
if [ "$bridge" = active ]; then
  echo "  wsl-clipbridge: active"
else
  echo "  wsl-clipbridge: ${bridge:-inactive}   <-- 运行：systemctl --user restart wsl-clipbridge"
  fail=1
fi
hb="$SHARE/agent.heartbeat"
if [ -f "$hb" ] && [ $(( $(date +%s) - $(stat -c %Y "$hb") )) -lt 10 ]; then
  echo "  clip-agent: 心跳正常"
else
  echo "  clip-agent: 心跳缺失/过期   <-- 运行：~/start-desktop.sh"
  fail=1
fi
if [ -z "${WAYLAND_DISPLAY:-}" ]; then
  echo "  内层 Wayland socket 不存在   <-- 桌面没在跑？先运行 ~/start-desktop.sh"
  exit 1
fi
echo

echo "=== 2) Linux -> Windows ==="
l2w="CLIPTEST_L2W_$(date +%H%M%S)"
if printf '%s' "$l2w" | timeout 3 wl-copy 2>/dev/null; then
  echo "  已在内层复制：$l2w"
  sleep 1
  inner=$(timeout 3 wl-paste -n -t text 2>/dev/null || true)
  if [ "$inner" = "$l2w" ]; then
    echo "  内层剪贴板读回正常"
  else
    echo "  内层剪贴板读回异常：${inner:-(空)}"
    fail=1
  fi
  sleep 2
  if command -v powershell.exe >/dev/null 2>&1; then
    win=$(timeout 20 powershell.exe -NoProfile -Command "Get-Clipboard -Raw" 2>/dev/null | tr -d '\r' | head -n1)
    if [ "$win" = "$l2w" ]; then
      echo "  ✅ Windows 剪贴板 = $win"
    else
      echo "  ❌ Windows 剪贴板 = ${win:-(空)}"
      fail=1
    fi
  else
    echo "  （没有 Windows 互操作，无法自动读回；请手工在 Windows 里粘贴验证）"
  fi
else
  echo "  wl-copy 失败（内层剪贴板不可用）"
  fail=1
fi
echo

echo "=== 3) Windows -> Linux ==="
w2l="CLIPTEST_W2L_$(date +%H%M%S)"
if command -v powershell.exe >/dev/null 2>&1; then
  timeout 20 powershell.exe -NoProfile -Command "Set-Clipboard -Value '$w2l'" >/dev/null 2>&1
  echo "  已在 Windows 剪贴板写入：$w2l"
  sleep 3
  inner=$(timeout 3 wl-paste -n -t text 2>/dev/null || true)
  if [ "$inner" = "$w2l" ]; then
    echo "  ✅ 内层剪贴板 = $inner"
  else
    echo "  ❌ 内层剪贴板 = ${inner:-(空)}"
    fail=1
  fi
else
  echo "  （没有 Windows 互操作，跳过；请手工在 Windows 复制文字后等 1 秒再运行 wl-paste 检查）"
fi
echo

if [ "$fail" -eq 0 ]; then
  echo "结果：双向文本剪贴板正常 ✅"
else
  echo "结果：有项目失败，见上面提示（先运行 ~/start-desktop.sh；仍失败看 TROUBLESHOOTING.md 第 6 节）"
fi
exit "$fail"
