#!/usr/bin/env bash
set -u
export XDG_RUNTIME_DIR=/run/user/1000
echo "=== wsl-desktop-session 单元 ==="
systemctl --user is-active wsl-desktop-session 2>&1
systemctl --user --no-pager status wsl-desktop-session 2>&1 | head -10
echo "=== gnome-session targets ==="
systemctl --user list-units --no-pager --all 'gnome-session*' 2>&1 | head -12
systemctl --user is-active 'gnome-session@ubuntu.target' 2>&1
echo "=== 相关进程 ==="
for n in gnome-session gnome-session-b gnome-session-binary gnome-session-init-worker gnome-session-ctl gnome-session-service gnome-shell mutter-devkit; do
  pgrep -a -x "$n" 2>/dev/null || true
done
echo "=== 谁在占用 org.gnome.SessionManager ==="
gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner org.gnome.SessionManager 2>&1
echo "--- 所有 gnome 相关的 DBus 名称 ---"
gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.ListNames 2>&1 | tr ',' '\n' | grep -i 'gnome\|session' | head -20
echo "=== 可能的锁文件 ==="
ls -la /run/user/1000/ 2>&1 | grep -iE 'gnome|session|XSESSION' || true
ls -la /tmp/ 2>&1 | grep -iE 'gnome|session' || true
echo "=== journal 最近 25 行 ==="
journalctl --user -n 25 --no-pager 2>&1 | tail -25
