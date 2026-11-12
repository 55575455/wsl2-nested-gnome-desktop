#!/bin/sh
# wsl-desktop: 让“Ubuntu 桌面窗口”走 X11，而 gnome-shell 启动的应用走嵌套 Wayland。
#
# 背景（TROUBLESHOOTING 4.9）：
#   - mutter-devkit 负责创建 Windows 上的「Mutter Development Kit」桌面窗口，必须走 X11
#     （WSLg 的 Xwayland :0），否则桌面窗口出不来；
#   - 但 gnome-shell 主进程本身不能带 GDK_BACKEND=x11：它启动的所有应用都会继承这个变量，
#     GTK 应用于是连到 WSLg 的 :0，窗口就跑到 Ubuntu 桌面外面、变成 Windows 上单独的窗口。
# 所以：用本包装脚本只给 mutter-devkit 强制 X11；gnome-shell 的 systemd override 不再设置
# GDK_BACKEND，只保留 DISPLAY=:0 + WAYLAND_DISPLAY=wayland-0（应用因此走嵌套 Wayland 桌面）。
GDK_BACKEND=x11
DISPLAY=:0
export GDK_BACKEND DISPLAY
exec /usr/libexec/mutter-devkit.real "$@"
