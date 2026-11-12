#!/usr/bin/env bash
# 以普通用户运行：让 snap 应用（Firefox/Thunderbird）的音频也走 WSLg
# 原理：snap 把 PULSE_SERVER 固定为 $XDG_RUNTIME_DIR/pulse/native（原本是 pipewire-pulse 的哑设备），
#       这里屏蔽 pipewire-pulse；该路径由 wslg-pulse-bind 常驻服务 bind mount 到 WSLg 音频。
set -u
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
echo "=== 屏蔽 pipewire-pulse（哑设备）==="
systemctl --user stop pipewire-pulse.socket pipewire-pulse.service 2>/dev/null || true
systemctl --user mask pipewire-pulse.socket pipewire-pulse.service 2>/dev/null || true
systemctl --user daemon-reload 2>/dev/null || true
echo "=== 会话 pulse socket（应为 WSLg PulseServer 的 bind mount）==="
ls -l "$XDG_RUNTIME_DIR/pulse/native" 2>&1
mountpoint "$XDG_RUNTIME_DIR/pulse/native" 2>&1 || true
echo "=== 通过该 socket 看音频服务（应看到 RDPSink）==="
LC_ALL=C timeout 8 pactl -s "unix:$XDG_RUNTIME_DIR/pulse/native" info 2>&1 | grep -E 'Server Name|Default Sink|Default Source' || echo "(连接失败)"
echo "=== 检查后台守护服务 ==="
systemctl --no-pager status wslg-pulse-bind.service 2>&1 | head -6 || true
