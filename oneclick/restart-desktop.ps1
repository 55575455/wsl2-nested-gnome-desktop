# ============================================================
# WSL2 嵌套 GNOME 桌面 —— 一键重开桌面（自包含，复制粘贴即可）
# 用法（Windows PowerShell）：
#   powershell -ExecutionPolicy Bypass -File .\restart-desktop.ps1
#   powershell -ExecutionPolicy Bypass -File .\restart-desktop.ps1 -Distro FedoraLinux-45
#   powershell -ExecutionPolicy Bypass -File .\restart-desktop.ps1 -Distro oracle-linux-10
#   -User 名字    指定用户（默认用发行版里的普通用户）
# ============================================================
param(
    [string]$Distro = '',
    [string]$User = ''
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
function Run-Wsl([string]$cmd) { return (& wsl.exe -d $Distro -u $User -- bash -lc $cmd 2>$null) }

Info "发行版：$Distro    用户：$User"

Step '1/3 停止旧桌面会话（含残留会话清理）'
& wsl.exe -d $Distro -u $User -- bash -lc 'if [ -x ~/stop-desktop.sh ]; then ~/stop-desktop.sh; else systemctl --user stop wsl-desktop-session 2>/dev/null; pkill -x gnome-shell 2>/dev/null; fi; echo done' 2>$null | Out-Null
Start-Sleep -Seconds 2
Info '已停止'

Step '2/3 启动桌面'
& wsl.exe -d $Distro -u $User -- bash -lc '~/start-desktop.sh' 2>$null | Out-Null
Start-Sleep -Seconds 20

Step '3/3 检查结果'
$cnt = ((Run-Wsl 'pgrep -c -x gnome-shell 2>/dev/null || echo 0') -join '').Trim()
Info "gnome-shell 进程数：$cnt"
if ($cnt -match '^\d+$' -and [int]$cnt -gt 0) {
    Info '桌面已启动（窗口标题「Mutter Development Kit」或「gnome-shell」，末尾带发行版名）'
} else {
    Warn '桌面没有启动成功，请查看 TROUBLESHOOTING.md 的“4. 桌面问题”'
    exit 1
}
