#!/usr/bin/env bash
# 持续记录 WSLg 音频状态（每 5 秒）到 /tmp/audio-watch.log，用于判断浏览器播放时什么时候、以什么形式卡死
set -u
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
LOG=/tmp/audio-watch.log
: > "$LOG"
while :; do
  ts=$(date +%H:%M:%S)
  if LC_ALL=C timeout 4 pactl -s unix:/mnt/wslg/PulseServer info >/tmp/pa-info.txt 2>&1; then
    health=OK
    sink=$(grep -m1 'Default Sink' /tmp/pa-info.txt | sed 's/.*: //')
    inputs=$(LC_ALL=C timeout 3 pactl -s unix:/mnt/wslg/PulseServer list short sink-inputs 2>/dev/null | wc -l)
  else
    health=FAIL
    sink=-
    inputs=-
  fi
  q=$(ss -xl 2>/dev/null | grep -m1 PulseServer | awk '{print $2"/"$3}' || true)
  echo "$ts health=$health sink=$sink inputs=$inputs queue=${q:-none}" >>"$LOG"
  sleep 5
done
