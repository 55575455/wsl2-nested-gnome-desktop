#!/usr/bin/env bash
# 在 WSL 里以 root 运行：安装剪贴板（双向文本桥 + Windows 侧代理），适用于任意普通用户名
set -eu

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
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
echo "目标用户: $TARGET_USER (home=$TARGET_HOME)"
SRC="$(cd "$(dirname "$0")/.." && pwd)"

# 1) WSL 侧桥脚本
install -m 0755 "$SRC/clipboard/clipbridge.sh" /usr/local/bin/clipbridge

# 2) Windows 侧代理（由 ~/start-desktop.sh 复制到 C:\Users\Public\wsl-desktop-clip 后启动）
install -d -m 0755 /usr/local/lib/wsl-desktop
install -m 0644 "$SRC/clipboard/clip-agent.ps1" /usr/local/lib/wsl-desktop/clip-agent.ps1

# 3) GNOME Shell 扩展（剪贴板同步在 shell 内部完成：不创建窗口、不抢焦点；
#    旧方案是每 0.2 秒跑一次 wl-paste，wl-clipboard 每次都会建一个临时窗口，
#    Dock 会把它当“未知应用”显示成齿轮图标反复闪烁）
EXT_SRC="$SRC/clipboard/extension"
EXT_DST=/usr/share/gnome-shell/extensions/clipbridge@wsl-desktop
install -d -m 0755 "$EXT_DST"
install -m 0644 "$EXT_SRC/metadata.json" "$EXT_SRC/extension.js" "$EXT_DST/"
echo "已安装 GNOME Shell 扩展: $EXT_DST"

# 4) 用户服务
install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/.config/systemd/user"
install -m 0644 "$SRC/clipboard/wsl-clipbridge.service" "$TARGET_HOME/.config/systemd/user/wsl-clipbridge.service"
chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.config/systemd/user/wsl-clipbridge.service"

# 5) 清理旧实例
pkill -f '/usr/local/bin/clipbridge' 2>/dev/null || true
rm -f /tmp/clipbridge.log /tmp/clipbridge.lock

echo "=== 剪贴板安装完成 ==="
ls -l /usr/local/bin/clipbridge /usr/local/lib/wsl-desktop/clip-agent.ps1 \
      "$TARGET_HOME/.config/systemd/user/wsl-clipbridge.service"
echo
echo "Windows 侧代理会由 ~/start-desktop.sh 自动启动；也可以手动运行："
echo "  powershell -NoProfile -ExecutionPolicy Bypass -File C:\\Users\\Public\\wsl-desktop-clip\\clip-agent.ps1"
