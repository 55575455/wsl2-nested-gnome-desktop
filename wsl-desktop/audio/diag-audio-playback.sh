#!/usr/bin/env bash
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export LC_ALL=C
echo "=== WSLg PA 健康 ==="
PULSE_SERVER=unix:/mnt/wslg/PulseServer timeout 5 pactl info 2>&1 | grep -E 'Server Name|Default Sink|Default Source' || echo '(FAIL)'
echo "=== sink 详情（volume/mute/state）==="
PULSE_SERVER=unix:/mnt/wslg/PulseServer timeout 5 pactl list sinks 2>&1 | grep -E 'Name:|State:|Mute:|Volume:|Sample Specification:' | head -12
echo "=== 当前播放流 ==="
PULSE_SERVER=unix:/mnt/wslg/PulseServer timeout 5 pactl list short sink-inputs 2>&1
echo "=== Firefox 客户端 ==="
PULSE_SERVER=unix:/mnt/wslg/PulseServer timeout 5 pactl list short clients 2>&1 | grep -i firefox || echo '(无 firefox 客户端)'
echo "=== 播放测试音（3 声，约 2 秒）==="
PULSE_SERVER=unix:/mnt/wslg/PulseServer timeout 15 paplay /usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga 2>&1; echo "paplay rc=$?"
echo "=== 播放后 sink 状态 ==="
PULSE_SERVER=unix:/mnt/wslg/PulseServer timeout 5 pactl list sinks 2>&1 | grep -E 'Name:|State:' | head -4
echo "=== weston.log 音频错误 ==="
grep -iE 'audio|rdpsnd|sink thread' /mnt/wslg/weston.log 2>/dev/null | tail -6
echo "=== PA 日志尾部 ==="
tail -n 8 /mnt/wslg/pulseaudio.log 2>&1
echo "=== 会话 socket 路径 ==="
ls -l /run/user/1000/pulse/native 2>&1
PULSE_SERVER=unix:/run/user/1000/pulse/native timeout 5 pactl info 2>&1 | grep -E 'Default Sink' || echo '(FAIL)'
