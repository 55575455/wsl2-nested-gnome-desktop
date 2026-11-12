#!/usr/bin/env bash
# 以普通用户运行：启用/重启剪贴板桥服务（适用于任意用户名）
# 注意：Windows 侧代理 clip-agent.ps1 由 ~/start-desktop.sh 自动拉起，
#       这里只管理 WSL 侧的桥服务；检查代理心跳：
#         ls -l /mnt/c/Users/Public/wsl-desktop-clip/agent.heartbeat
set -u
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
systemctl --user daemon-reload
systemctl --user enable wsl-clipbridge >/dev/null 2>&1 || true
systemctl --user restart wsl-clipbridge
sleep 1
echo "剪贴板桥: $(systemctl --user is-active wsl-clipbridge) / $(systemctl --user is-enabled wsl-clipbridge)"
echo "代理心跳: $(ls -l /mnt/c/Users/Public/wsl-desktop-clip/agent.heartbeat 2>/dev/null || echo '不存在（启动桌面后由 ~/start-desktop.sh 拉起）')"
systemctl --user --no-pager status wsl-clipbridge 2>&1 | head -8 || true
