# ============================================================
# WSL2 嵌套 GNOME 桌面 —— 一键修声音（自包含，复制粘贴即可）
# 用法（Windows PowerShell）：
#   powershell -ExecutionPolicy Bypass -File .\fix-audio.ps1
# 可选：
#   -SkipWslRestart   不重启 WSL（只做热重启）
#   -Distro 名字      发行版名（默认自动：有 Ubuntu 用 Ubuntu，否则用第一个）
#   -User 名字        指定用户（默认用发行版里的普通用户）
#
# 2026-11-12 起的新流程（实测热重启约 3 秒恢复，通常无需重启 WSL）：
#   1) 在 WSL 里运行 ~/start-desktop.sh --fix：
#        同步自检音频 → 卡死就关掉声音面板并热重启 WSLg PulseAudio
#                → 拉起 Windows 剪贴板代理 + 启动剪贴板桥（不启动桌面）
#   2) 仍然无声 → 再手工热重启一次
#   3) 仍然无声 → 重启 WSL（wsl --shutdown）后重开桌面
#   4) 打印声音 / 剪贴板最终状态
# ============================================================
param(
    [string]$Distro = '',
    [string]$User = '',
    [switch]$SkipWslRestart
)
$ErrorActionPreference = 'Continue'
$env:WSL_UTF8 = '1'

if (-not $Distro) {
    $raw = & wsl.exe -l -q 2>$null
    $list = @()
    foreach ($line in $raw) {
        $n = (($line -replace "`0", '')).Trim()
        if ($n -and $n -notmatch '^docker-desktop') { $list += $n }
    }
    if ($list.Count -eq 0) { Write-Host '[失败] 一个 WSL 发行版都没找到。' -ForegroundColor Red; exit 1 }
    if ($list -contains 'Ubuntu') { $Distro = 'Ubuntu' } else { $Distro = $list[0] }
}
if (-not $User) {
    $u = ((& wsl.exe -d $Distro -- id -un 2>$null) -join '').Trim()
    if ($u -eq 'root') {
        $hasU = ((& wsl.exe -d $Distro -u root -- bash -lc 'getent passwd u >/dev/null 2>&1 && echo YES' 2>$null) -join '').Trim()
        if ($hasU -match 'YES') { $u = 'u' }
    }
    $User = $u
}
if ($User -eq 'root' -or -not $User) {
    Write-Host "[失败] 发行版 $Distro 的默认用户是 root（GNOME 不能以 root 运行）。请先运行 oneclick/install.ps1 -Distro $Distro。" -ForegroundColor Red
    exit 1
}

function Step([string]$m) { Write-Host "`n===== $m =====" -ForegroundColor Cyan }
function Info([string]$m) { Write-Host "  $m" }
function Warn([string]$m) { Write-Host "  [!] $m" -ForegroundColor Yellow }
function Ok([string]$m)   { Write-Host "  [OK] $m" -ForegroundColor Green }

function Run-Wsl([string]$cmd) { return (& wsl.exe -d $Distro -u $User -- bash -lc $cmd 2>$null) }

function CheckAudio {
    $r = ((Run-Wsl 's=$(LC_ALL=C timeout 6 pactl -s unix:/mnt/wslg/PulseServer list short sinks 2>/dev/null); [ -n "$s" ] && echo AUDIO_OK || echo AUDIO_FAIL') -join '').Trim()
    return ($r -match 'AUDIO_OK')
}

function AudioSink {
    $r = ((Run-Wsl 'LC_ALL=C timeout 6 pactl -s unix:/mnt/wslg/PulseServer list short sinks 2>/dev/null | head -n1 | cut -f2') -join '').Trim()
    if ($r) { return $r } else { return '(未取到)' }
}

function CheckClipAgent {
    $r = ((Run-Wsl 'hb=/mnt/c/Users/Public/wsl-desktop-clip/agent.heartbeat; age=99999; [ -f $hb ] && age=$(( $(date +%s) - $(stat -c %Y $hb) )); [ $age -lt 10 ] && echo AGENT_OK || echo AGENT_FAIL') -join '').Trim()
    return ($r -match 'AGENT_OK')
}

function CheckBridge {
    $r = ((Run-Wsl 'systemctl --user is-active wsl-clipbridge 2>/dev/null || true') -join '').Trim()
    return ($r -match 'active')
}

function StartDesktop {
    & wsl.exe -d $Distro -u $User -- bash -lc 'systemd-run --user --unit=wsl-desktop-session --collect ~/start-desktop.sh' 2>$null | Out-Null
}

# ---- 1) 让 start-desktop.sh 自检/热重启音频，并拉起剪贴板代理 ----
Step '1/4 运行 ~/start-desktop.sh --fix（同步热重启音频 + 拉起剪贴板代理/桥，不启动桌面）'
$out = Run-Wsl '~/start-desktop.sh --fix 2>&1'
$out | ForEach-Object { Info $_ }
Start-Sleep -Seconds 3
$audioOk = CheckAudio
if ($audioOk) {
    Ok ("声音已恢复正常，默认输出：" + (AudioSink))
} else {
    Warn 'start-desktop.sh 后音频仍不正常，尝试手工热重启'
}

# ---- 2) 手工热重启 WSLg PulseAudio ----
if (-not $audioOk) {
    Step '2/4 手工热重启 WSLg 的 PulseAudio'
    & wsl.exe -d $Distro -u $User -- bash -lc 'pkill -f gnome-control-center 2>/dev/null; true' 2>$null | Out-Null
    & wsl.exe --system -- sh -c 'pkill -9 pulseaudio' 2>$null | Out-Null
    Start-Sleep -Seconds 8
    $audioOk = CheckAudio
    if ($audioOk) { Ok ("音频已恢复，默认输出：" + (AudioSink)) } else { Warn '热重启无效' }
}

# ---- 3) 还不行 → 重启 WSL ----
if (-not $audioOk) {
    Step '3/4 重启 WSL（会关闭当前桌面窗口）'
    if ($SkipWslRestart) {
        Warn '已指定 -SkipWslRestart，跳过重启 WSL'
    } else {
        & wsl.exe -d $Distro -u $User -- bash -lc '~/stop-desktop.sh 2>/dev/null || true' 2>$null | Out-Null
        wsl.exe --shutdown
        Start-Sleep -Seconds 10
        Info '重新启动桌面…'
        StartDesktop
        Start-Sleep -Seconds 25
        $audioOk = CheckAudio
        if ($audioOk) { Ok ("音频已恢复，默认输出：" + (AudioSink)) } else { Warn '重启 WSL 后仍不正常' }
    }
}

# ---- 4) 结果 ----
Step '4/4 最终状态'
if ($audioOk) {
    Ok ("声音：正常（" + (AudioSink) + "）")
} else {
    Warn '声音：仍不正常'
}
if (CheckClipAgent) { Ok '剪贴板代理（Windows 侧）：在跑' } else { Warn '剪贴板代理：没在跑（可运行 oneclick/restart-desktop.ps1）' }
if (CheckBridge)    { Ok '剪贴板桥（WSL 侧）：active' } else { Warn '剪贴板桥：inactive（WSL 里运行 systemctl --user restart wsl-clipbridge）' }

if ($audioOk) {
    Write-Host @'

下一步：在 WSL 终端里放一段测试音：
  PULSE_SERVER=unix:/mnt/wslg/PulseServer paplay /usr/share/sounds/freedesktop/stereo/complete.oga

如果命令不报错但听不到声音，请检查：
  1) Windows 右下角喇叭图标里选的输出设备是不是你正在用的那个；
  2) 音量不是 0、没有静音（本机默认设备应显示为「扬声器 (High Definition Audio Device)」之类）；
  3) 蓝牙耳机/USB 声卡没连好时，切回内置扬声器再试。

剪贴板：Windows 里复制一段文字 → 等 1 秒 → 桌面里粘贴；
         桌面里复制 → 等 1 秒 → Windows 里粘贴。日志：
  C:\Users\Public\wsl-desktop-clip\agent.log
  WSL: /tmp/clipbridge.log
'@
} else {
    Write-Host @'

[仍未恢复] 请按顺序试：
  1) 再运行一次本脚本（有时需要第二次）；
  2) 看 C:\Users\Public\wsl-desktop-clip\agent.log 里有没有反复 audio FAIL；
  3) 按 TROUBLESHOOTING.md 的 5.2 / 5.6 节处理；
  4) 最后手段：wsl --shutdown，重新打开该发行版的终端，运行 ~/start-desktop.sh
'@
    exit 1
}
