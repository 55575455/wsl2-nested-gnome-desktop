<#
  显示 / 填写本机实际路径（公开仓库·脱敏版必读）

  公开仓库里的文档和脚本是“脱敏版”：所有个人路径都被替换成了占位符，例如
      C:\Users\<用户名>            → 你 Windows 用户目录
      /home/<用户名>               → 你 WSL 用户目录
      <用户名>                     → 你的用户名
      <主机名>                     → 你的主机名
      ~/wsl2-nested-gnome-desktop  → 你实际放仓库的位置
  **使用前必须把它们换成你本机的真实路径**，否则路径不存在，安装/启动会失败。

  本脚本会：
    1) 显示本机实际值（Windows 路径、WSL 发行版/用户/home、仓库的实际位置）；
    2) 列出仓库里所有“含占位符的文件”和出现次数；
    3) 打印「占位符 → 你的实际值」对照表，照着填即可；
    4) 加 -Apply 参数可自动替换（替换前会逐个列出将要修改的文件）。

  用法（Windows PowerShell）：
    powershell -ExecutionPolicy Bypass -File .\oneclick\show-paths.ps1
    powershell -ExecutionPolicy Bypass -File .\oneclick\show-paths.ps1 -Apply

  参数：
    -Apply        自动把占位符替换成本机实际值（会修改文档/脚本，建议先 git status）
    -RepoRoot <路径>  仓库根目录（默认根据本脚本位置自动推断）
#>
param(
    [switch]$Apply,
    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Continue'
$env:WSL_UTF8 = '1'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

function Write-Head([string]$text) {
    Write-Host ''
    Write-Host ('=' * 66) -ForegroundColor DarkCyan
    Write-Host ('  ' + $text) -ForegroundColor Cyan
    Write-Host ('=' * 66) -ForegroundColor DarkCyan
}
function Write-Item([string]$k, [string]$v) {
    Write-Host ('  {0,-24} : {1}' -f $k, $v)
}
function Run-Wsl([string[]]$argsList) {
    try {
        $out = & wsl.exe @argsList 2>$null
        return ($out -join "`n")
    } catch { return '' }
}

# ---------- 1. 推断仓库根目录 ----------
if (-not $RepoRoot) {
    if ($PSScriptRoot) {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
    } else {
        $RepoRoot = (Get-Location).Path
    }
}
if (-not (Test-Path -LiteralPath $RepoRoot)) {
    Write-Host ("[错误] 找不到仓库目录：$RepoRoot") -ForegroundColor Red
    exit 1
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$RepoName = Split-Path -Leaf $RepoRoot

Write-Head '本机实际值（这些就是要填进去的内容）'
$winUser  = $env:USERNAME
$winHome  = $env:USERPROFILE
$winHost  = $env:COMPUTERNAME
Write-Item 'Windows 用户名' $winUser
Write-Item 'Windows 用户目录' $winHome
Write-Item 'Windows 计算机名' $winHost
Write-Item '仓库在 Windows 的位置' $RepoRoot

# ---------- 2. 探测 WSL ----------
$distros = @()
$defaultDistro = ''
$wslList = Run-Wsl @('--list', '--verbose')
foreach ($line in ($wslList -split "`n")) {
    $t = ($line -replace "`0", '').TrimEnd()
    if ($t -match '^\s*\*\s*(\S+)') { $defaultDistro = $Matches[1]; $distros += $Matches[1] }
    elseif ($t -match '^\s+(\S+)\s+\S+\s+\d+\s*$') { $distros += $Matches[1] }
}
if (-not $distros -or $distros.Count -eq 0) {
    $q = Run-Wsl @('--list', '--quiet')
    $distros = @(($q -split "`n") | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ })
}
$distro = if ($defaultDistro) { $defaultDistro } elseif ($distros.Count -gt 0) { $distros[0] } else { 'Ubuntu' }
Write-Item 'WSL 发行版（默认）' $distro
if ($distros.Count -gt 0) { Write-Item 'WSL 发行版列表' ($distros -join ', ') }

$wslUser = (Run-Wsl @('-d', $distro, '--', 'bash', '-lc', 'id -un')).Trim()
$wslHome = (Run-Wsl @('-d', $distro, '--', 'bash', '-lc', 'echo $HOME')).Trim()
$wslHost = (Run-Wsl @('-d', $distro, '--', 'bash', '-lc', 'hostname')).Trim()
if (-not $wslUser) { $wslUser = $winUser }
if (-not $wslHome) { $wslHome = '/home/' + $wslUser }
if (-not $wslHost) { $wslHost = $winHost }

Write-Item 'WSL 默认用户' $wslUser
Write-Item 'WSL 用户 home' $wslHome
Write-Item 'WSL 主机名' $wslHost

# 仓库在 WSL 里的路径：C:\... → /mnt/c/...（避免依赖 wslpath 的参数转义）
$wslRepo = ''
if ($RepoRoot -match '^([A-Za-z]):\\(.*)$') {
    $drive = $Matches[1].ToLower()
    $rest = ($Matches[2] -replace '\\', '/')
    $wslRepo = ('/mnt/{0}/{1}' -f $drive, $rest)
} else {
    $wslRepo = (Run-Wsl @('-d', $distro, '--', 'wslpath', '-u', $RepoRoot)).Trim()
}
if (-not $wslRepo) { $wslRepo = $RepoRoot }
Write-Item '仓库在 WSL 的路径' $wslRepo
Write-Host ('  （如果你是在 WSL 里 clone 的，WSL 路径就是 ~/{0}；上面显示的是当前这份仓库的实际位置）' -f $RepoName)

# ---------- 3. 占位符 → 实际值 ----------
$mapping = @(
    @{ Token = 'C:\Users\<用户名>';            Value = $winHome;                          Desc = 'Windows 用户目录（用 Windows 用户名）' },
    @{ Token = '/home/<用户名>';               Value = $wslHome;                          Desc = 'WSL 用户目录（用 WSL 用户名）' },
    @{ Token = '<用户名>@<主机名>';            Value = ($wslUser + '@' + $wslHost);       Desc = '提示符里的 用户@主机（WSL）' },
    @{ Token = '-u <用户名>';                  Value = ('-u ' + $wslUser);                Desc = 'wsl 命令里的 WSL 用户名' },
    @{ Token = '<用户名>';                     Value = $winUser;                          Desc = '用户名（一般指 Windows 用户名）' },
    @{ Token = '<主机名>';                     Value = $wslHost;                          Desc = '主机名（WSL）' },
    @{ Token = '~/wsl2-nested-gnome-desktop';  Value = $wslRepo;                          Desc = '仓库的实际位置（WSL 路径）' }
)

Write-Head '要求（使用公开仓库前必须做）'
Write-Host '  1) 公开仓库（脱敏版）里，文档/脚本中的个人路径都是占位符；'
Write-Host '  2) 必须把所有占位符替换成你本机的实际值（下表就是对照表）；'
Write-Host '  3) 可以用本脚本的 -Apply 参数自动替换，或照着下表手动改；'
Write-Host '  4) 不替换的话，命令里的路径会指向不存在的位置，安装/启动会失败。'

Write-Head '占位符 → 你的实际值（照着填）'
foreach ($m in $mapping) {
    Write-Host ('  {0,-28} →  {1}' -f $m.Token, $m.Value) -ForegroundColor Green
    Write-Host ('  {0,-28}    ({1})' -f '', $m.Desc) -ForegroundColor DarkGray
}

# ---------- 4. 扫描含占位符的文件 ----------
$textExt = @('.md', '.ps1', '.sh', '.service', '.txt')
$selfPath = ''
try { $selfPath = (Resolve-Path -LiteralPath $MyInvocation.MyCommand.Path).Path } catch { }
$scanFiles = Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
        $_.FullName -notmatch '[\\/]\.git[\\/]' -and
        ($textExt -contains $_.Extension -or $_.Name -in @('.gitignore', '.gitattributes')) -and
        ($_.Name -notin @('show-paths.ps1', 'show-paths.sh')) -and
        ($selfPath -eq '' -or $_.FullName -ne $selfPath)
    }

$found = @()
foreach ($f in $scanFiles) {
    $txt = ''
    try { $txt = [IO.File]::ReadAllText($f.FullName) } catch { continue }
    $counts = @()
    foreach ($m in $mapping) {
        $c = ([regex]::Matches($txt, [regex]::Escape($m.Token))).Count
        if ($c -gt 0) { $counts += ('{0}×{1}' -f $m.Token, $c) }
    }
    if ($counts.Count -gt 0) {
        $found += [pscustomobject]@{
            Rel   = $f.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
            Count = ($counts -join '，')
            Path  = $f.FullName
        }
    }
}

Write-Head '含占位符的文件（这些就是“公开仓库的脱敏文件位置”）'
if ($found.Count -eq 0) {
    Write-Host '  未发现占位符：本仓库看起来已经是实际路径版，不需要填写。' -ForegroundColor Yellow
} else {
    Write-Host ('  共 {0} 个文件需要检查/填写：' -f $found.Count)
    foreach ($x in $found) {
        Write-Host ('  - {0}' -f $x.Rel) -ForegroundColor Yellow
        Write-Host ('      占位符：{0}' -f $x.Count) -ForegroundColor DarkGray
        Write-Host ('      绝对路径：{0}' -f $x.Path) -ForegroundColor DarkGray
    }
}

# ---------- 5. 自动替换（可选） ----------
if ($Apply) {
    Write-Head '开始自动替换（-Apply）'
    if ($found.Count -eq 0) {
        Write-Host '  没有需要替换的内容。'
        exit 0
    }
    $changed = 0
    foreach ($x in $found) {
        $p = $x.Path
        $bytes = [IO.File]::ReadAllBytes($p)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $txt = [IO.File]::ReadAllText($p)
        $orig = $txt
        foreach ($m in $mapping) { $txt = $txt.Replace($m.Token, $m.Value) }
        if ($txt -ne $orig) {
            $enc = if ($hasBom) { New-Object System.Text.UTF8Encoding($true) } else { New-Object System.Text.UTF8Encoding($false) }
            [IO.File]::WriteAllText($p, $txt, $enc)
            $changed++
            Write-Host ('  已替换：{0}' -f $x.Rel) -ForegroundColor Green
        }
    }
    Write-Host ''
    Write-Host ('  完成：修改了 {0} 个文件。' -f $changed) -ForegroundColor Green
    Write-Host '  建议：git status 看一下改动；如果你要把改动推回仓库，请先确认没有混入个人信息。'
} else {
    Write-Head '下一步'
    Write-Host '  先按上面的对照表手工填写；也可以直接自动替换（会修改文件）：'
    Write-Host ''
    Write-Host '    powershell -ExecutionPolicy Bypass -File .\oneclick\show-paths.ps1 -Apply'
    Write-Host ''
}
