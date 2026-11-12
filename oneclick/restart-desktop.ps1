# ============================================================
# WSL2 嵌套 GNOME 桌面 —— 一键重开桌面（自包含，复制粘贴即可）
# 用法（Windows PowerShell）：
#   powershell -ExecutionPolicy Bypass -File .\restart-desktop.ps1
# ============================================================
param(
    [string]$Distro = 'Ubuntu'
)
$ErrorActionPreference = 'Continue'
$env:WSL_UTF8 = '1'

function Step([string]$m) { Write-Host "`n===== $m =====" -ForegroundColor Cyan }
function Info([string]$m) { Write-Host "  $m" }
function Warn([string]$m) { Write-Host "  [!] $m" -ForegroundColor Yellow }
function Run-Wsl([string]$cmd) { return (& wsl.exe -d $Distro -- bash -lc $cmd 2>$null) }

Step '1/3 停止旧桌面会话（含残留会话清理）'
& wsl.exe -d $Distro -- bash -lc 'if [ -x ~/stop-desktop.sh ]; then ~/stop-desktop.sh; else systemctl --user stop wsl-desktop-session 2>/dev/null; systemctl --user stop "gnome-session@ubuntu.target" 2>/dev/null; pkill -x gnome-shell 2>/dev/null; fi; echo done' 2>$null | Out-Null
Start-Sleep -Seconds 2
Info '已停止'

Step '2/3 启动桌面'
& wsl.exe -d $Distro -- bash -lc 'systemd-run --user --unit=wsl-desktop-session --collect ~/start-desktop.sh' 2>$null | Out-Null
Start-Sleep -Seconds 20

Step '3/3 检查结果'
$cnt = ((Run-Wsl 'pgrep -c -x gnome-shell 2>/dev/null || echo 0') -join '').Trim()
Info "gnome-shell 进程数：$cnt"
if ($cnt -match '^\d+$' -and [int]$cnt -gt 0) {
    Info '桌面已启动，窗口标题为「Mutter Development Kit」'
} else {
    Warn '桌面没有启动成功，请查看 TROUBLESHOOTING.md 的“4. 桌面问题”'
    exit 1
}
