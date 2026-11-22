# ============================================================
# 一键启动 / 查看 / 停止 WSL 里的嵌套 GNOME 桌面（自包含，复制粘贴即可）
#
# 特点：启动后**立即返回，不占用当前终端/窗口**（桌面由 systemd 用户单元托管）。
#
# 用法（Windows PowerShell）：
#   powershell -ExecutionPolicy Bypass -File .\start-desktop.ps1            # 后台启动
#   powershell -ExecutionPolicy Bypass -File .\start-desktop.ps1 -Status    # 查看状态
#   powershell -ExecutionPolicy Bypass -File .\start-desktop.ps1 -Stop      # 停止桌面
#   powershell -ExecutionPolicy Bypass -File .\start-desktop.ps1 -FixOnly   # 只修声音/剪贴板
#   powershell -ExecutionPolicy Bypass -File .\start-desktop.ps1 -Wait      # 启动并等桌面窗口出现
#
# 也可以直接双击同目录的 start-desktop.cmd（自动定位脚本，和当前目录无关）。
#
# ⚠️ 如果提示 “-File 形式参数的实际参数“.\oneclick\start-desktop.ps1”不存在”：
#    说明当前 PowerShell 目录不是仓库根目录（例如从开始菜单打开时默认在 C:\windows\System32）。
#    先 cd 到仓库目录，或用完整路径运行，或直接双击 start-desktop.cmd。
#
# 参数：
#   -Distro    WSL 发行版名（默认自动：有 Ubuntu 用 Ubuntu，否则用第一个）
#   -User      指定用户（默认用发行版里的普通用户）
#   -Status    只查看状态
#   -Stop      停止桌面
#   -FixOnly   只修复声音/剪贴板，不启动桌面
#   -Wait      启动后最多等 90 秒，直到 gnome-shell 出现
#   -Quiet     少打印
# ============================================================
param(
    [string]$Distro = '',
    [string]$User = '',
    [switch]$Status,
    [switch]$Stop,
    [switch]$FixOnly,
    [switch]$Wait,
    [switch]$Quiet
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

function Info([string]$m) { if (-not $Quiet) { Write-Host $m } }
function Fail([string]$m) { Write-Host "[失败] $m" -ForegroundColor Red; exit 1 }
function Run-Wsl([string]$cmd) {
    if ($User) { return (& wsl.exe -d $Distro -u $User -- bash -lc $cmd 2>&1) }
    return (& wsl.exe -d $Distro -- bash -lc $cmd 2>&1)
}
function ShellCount {
    $r = ((Run-Wsl 'pgrep -c -x gnome-shell 2>/dev/null || echo 0') -join '').Trim()
    if ($r -match '^\d+$') { return [int]$r } else { return 0 }
}
function Print-Check {
    $lines = Run-Wsl '~/start-desktop.sh --check 2>&1'
    foreach ($l in $lines) {
        if ($l -match '^(gnome-shell|桌面模式|wsl-desktop-session|会话状态|声音服务|pulse socket|剪贴板代理|剪贴板桥|桌面图标扩展|Dock 运行图标|应用窗口归属|剪贴板同步)') { Info $l }
    }
}

# ---- 检查 WSL ----
$probe = ((Run-Wsl 'echo WSL_OK') -join '').Trim()
if ($probe -notmatch 'WSL_OK') {
    Fail "无法进入 WSL 发行版 '$Distro'。请用 -Distro 指定正确名字（wsl -l -v 查看），或先运行 oneclick/install.ps1。"
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
    Fail "发行版 $Distro 的默认用户是 root（GNOME 不能以 root 运行）。请先运行 oneclick/install.ps1 -Distro $Distro（会创建普通用户 u）。"
}
Info "发行版：$Distro    用户：$User"

if ($Stop) {
    Info '正在停止桌面…'
    (Run-Wsl '~/start-desktop.sh --stop') | ForEach-Object { Info $_ }
    Info '已停止。'
    exit 0
}

if ($Status) {
    Info '===== 桌面状态 ====='
    (Run-Wsl '~/start-desktop.sh --check') | ForEach-Object { Info $_ }
    exit 0
}

if ($FixOnly) {
    Info '===== 只修复声音/剪贴板 ====='
    (Run-Wsl '~/start-desktop.sh --fix') | ForEach-Object { Info $_ }
    exit 0
}

# ---- 启动 ----
Info '正在启动桌面（后台运行，立即返回，不会占用这个窗口）…'
$startOut = Run-Wsl '~/start-desktop.sh'
$startOut | ForEach-Object { Info $_ }
$startText = $startOut -join "`n"
$alreadyRunning = $startText -match '已经在运行'
$cleanedStale = $startText -match '残留的桌面单元'

# 后台启动后 shell 通常 1~15 秒内出现；-Wait 时最多等 90 秒
$timeoutSec = if ($Wait) { 90 } else { 15 }
if ($Wait) { Info '等待桌面窗口出现（最多 90 秒）…' }
$deadline = (Get-Date).AddSeconds($timeoutSec)
while ((Get-Date) -lt $deadline) {
    if ((ShellCount) -gt 0) { break }
    Start-Sleep -Seconds 2
}

$n = ShellCount
Info ''
if ($n -gt 0 -and $alreadyRunning) {
    Info '✅ 桌面已经在运行（没有重复启动）。'
} elseif ($n -gt 0) {
    Info '✅ 桌面已启动（窗口标题「Mutter Development Kit」或「gnome-shell」，标题末尾带发行版名）。'
} elseif ($cleanedStale) {
    Info '已清理残留桌面单元并启动，窗口通常 10~20 秒内出现；稍等再运行：'
    Info '   powershell -ExecutionPolicy Bypass -File .\start-desktop.ps1 -Status'
} else {
    Info '桌面进程还没出现；后台启动通常需要 10~20 秒，稍等再运行：'
    Info '   powershell -ExecutionPolicy Bypass -File .\start-desktop.ps1 -Status'
}
Info '----- 当前状态 -----'
Print-Check
Info ''
Info '提示：关闭桌面窗口 = 关闭桌面；重新打开运行本脚本即可。'
Info '      重复执行原 systemd-run 命令会报 “Unit ... already loaded”（单元已存在），属正常，不用管；本脚本可重复运行。'
Info '      在任意目录运行：用完整路径，或先 cd 到仓库目录；双击 start-desktop.cmd 也可以（自动定位）。'
