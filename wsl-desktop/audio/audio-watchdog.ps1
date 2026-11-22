#!/usr/bin/env pwsh
# WSLg 音频看门狗（Windows 侧后台运行）——旧版脚本，保留作参考
#
# 2026-11-12 起：看门狗已内置进剪贴板代理 wsl-desktop/clipboard/clip-agent.ps1
# （每 20 秒检测一次，卡死自动关声音面板 + 热重启 WSLg 的 PulseAudio，日志在
#  C:\Users\Public\wsl-desktop-clip\agent.log），由 ~/start-desktop.sh 自动拉起。
# 正常情况下不需要再单独运行本脚本。
#
# 若仍想独立使用本脚本：
#   每 20 秒检查一次 WSLg 音频；卡死时：
#     1) 关掉「设置 > 声音」面板（它是卡死的常见触发器）
#     2) 热重启 WSLg 的 PulseAudio（WSLGd 自动拉起；bind 守护自动重挂 socket）
#   连续 3 次无效则暂停 5 分钟（避免死循环），并提示运行 oneclick/fix-audio.ps1
#
# 用法（Windows PowerShell）：
#   powershell -ExecutionPolicy Bypass -File audio-watchdog.ps1
# 想开机常驻：把上面命令做成“任务计划程序”的登录时任务即可。
param(
    [string]$Distro = 'Ubuntu'
)
$ErrorActionPreference = 'Continue'
$env:WSL_UTF8 = '1'
$log = Join-Path $env:TEMP 'wslg-audio-watchdog.log'

function Log([string]$m) {
    Add-Content -Path $log -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding utf8
}

function CheckAudio {
    $r = ((& wsl.exe -d $Distro -- bash -lc 'export XDG_RUNTIME_DIR=/run/user/$(id -u); LC_ALL=C timeout 5 pactl -s unix:/mnt/wslg/PulseServer info >/dev/null 2>&1 && echo OK || echo FAIL' 2>$null) -join '').Trim()
    return ($r -match 'OK')
}

Log 'watchdog started'
$failures = 0
while ($true) {
    Start-Sleep -Seconds 20
    if (CheckAudio) {
        $failures = 0
        continue
    }
    $failures++
    Log "PulseAudio wedged (连续失败 $failures)，关闭声音面板并热重启音频"
    & wsl.exe -d $Distro -- bash -lc 'pkill -x gnome-control-center 2>/dev/null; echo done' 2>$null | Out-Null
    & wsl.exe --system -- sh -c "pkill -9 pulseaudio" 2>$null | Out-Null
    Start-Sleep -Seconds 8
    if (CheckAudio) {
        Log '热重启恢复'
        $failures = 0
        continue
    }
    Log '热重启无效'
    if ($failures -ge 3) {
        Log '连续 3 次失败，暂停 5 分钟；建议运行 oneclick/fix-audio.ps1（重启 WSL）'
        Start-Sleep -Seconds 300
        $failures = 0
    }
}
