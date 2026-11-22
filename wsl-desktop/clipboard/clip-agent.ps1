<#
  WSLg nested GNOME desktop - Windows side agent (clipboard + audio watchdog).

  Started automatically by ~/start-desktop.sh (through WSL interop) and runs hidden.
  Can also be run manually:
      powershell -NoProfile -ExecutionPolicy Bypass -File clip-agent.ps1

  Jobs:

  1) Clipboard bridge (TEXT ONLY, both directions)
     Files in C:\Users\Public\wsl-desktop-clip (created here):
       win.txt          snapshot of the Windows clipboard (UTF-8, no BOM)
       linux.req.txt    text the Linux side wants written into the Windows clipboard
       agent.heartbeat  timestamp, refreshed while this process is alive
       agent.log        log (rotated when it grows big)
     /usr/local/bin/clipbridge mirrors win.txt into the nested GNOME clipboard and
     writes linux.req.txt when you copy inside GNOME.

     Clipboard access uses raw Win32 calls (OpenClipboard / CF_UNICODETEXT) instead
     of the PowerShell Get/Set-Clipboard cmdlets: if another process holds the
     clipboard open those cmdlets could block this agent forever, raw calls just
     fail fast and are retried on the next loop.

  2) WSLg audio watchdog
     Every AudioCheckSec seconds it asks WSL whether WSLg PulseAudio still accepts
     connections. WSLg PulseAudio regularly wedges itself (RDP sink queue overrun),
     which shows up in GNOME as "no output device". In that case the agent closes
     the Sound settings panel and kills the system-distro pulseaudio process so
     WSLGd can start a fresh one (no wsl --shutdown needed).
#>
param(
    [string]$ShareDir      = 'C:\Users\Public\wsl-desktop-clip',
    [string]$Distro        = 'Ubuntu',
    [int]$PollMs           = 250,
    [int]$AudioCheckSec    = 20,
    [int]$MaxLogBytes      = 262144,
    [switch]$NoAudioWatch
)

$ErrorActionPreference = 'Continue'
$env:WSL_UTF8 = '1'

New-Item -ItemType Directory -Force -Path $ShareDir | Out-Null
Set-Location -LiteralPath $ShareDir
$winFile  = Join-Path $ShareDir 'win.txt'
$reqFile  = Join-Path $ShareDir 'linux.req.txt'
$hbFile   = Join-Path $ShareDir 'agent.heartbeat'
$logFile  = Join-Path $ShareDir 'agent.log'
$lockFile = Join-Path $ShareDir 'agent.lock'

$script:Utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-Log([string]$m) {
    try {
        $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    } catch { }
}

function Read-TextFile([string]$p) {
    try {
        if (-not (Test-Path -LiteralPath $p)) { return $null }
        return [System.IO.File]::ReadAllText($p, $script:Utf8)
    } catch { return $null }
}

function Write-TextFile([string]$p, [string]$t) {
    $tmp = '{0}.{1}.tmp' -f $p, $PID
    try {
        [System.IO.File]::WriteAllText($tmp, $t, $script:Utf8)
        $moved = $false
        for ($i = 0; $i -lt 5 -and -not $moved; $i++) {
            try { Move-Item -LiteralPath $tmp -Destination $p -Force; $moved = $true }
            catch { Start-Sleep -Milliseconds 100 }
        }
        if (-not $moved) {
            [System.IO.File]::WriteAllText($p, $t, $script:Utf8)
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        return $true
    } catch { return $false }
}

# ---- Win32 clipboard helpers (never block forever) -------------------------
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

public static class WslClip {
    [DllImport("user32.dll", SetLastError = true)] static extern bool OpenClipboard(IntPtr hWndNewOwner);
    [DllImport("user32.dll", SetLastError = true)] static extern bool CloseClipboard();
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr GetClipboardData(uint uFormat);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SetClipboardData(uint uFormat, IntPtr hMem);
    [DllImport("user32.dll", SetLastError = true)] static extern bool EmptyClipboard();
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr GlobalAlloc(uint uFlags, UIntPtr dwBytes);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr GlobalLock(IntPtr hMem);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GlobalUnlock(IntPtr hMem);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr GlobalFree(IntPtr hMem);

    const uint CF_UNICODETEXT = 13;
    const uint GMEM_MOVEABLE = 2;

    // Returns null when the clipboard cannot be opened right now.
    public static string GetText() {
        for (int attempt = 0; attempt < 3; attempt++) {
            if (!OpenClipboard(IntPtr.Zero)) { Thread.Sleep(20); continue; }
            try {
                IntPtr h = GetClipboardData(CF_UNICODETEXT);
                if (h == IntPtr.Zero) { return string.Empty; }
                IntPtr p = GlobalLock(h);
                if (p == IntPtr.Zero) { return string.Empty; }
                try { return Marshal.PtrToStringUni(p) ?? string.Empty; }
                finally { GlobalUnlock(h); }
            } finally { CloseClipboard(); }
        }
        return null;
    }

    public static bool SetText(string text) {
        if (text == null) { return false; }
        for (int attempt = 0; attempt < 5; attempt++) {
            if (!OpenClipboard(IntPtr.Zero)) { Thread.Sleep(20); continue; }
            try {
                EmptyClipboard();
                IntPtr h = GlobalAlloc(GMEM_MOVEABLE, (UIntPtr)((text.Length + 1) * 2));
                if (h == IntPtr.Zero) { return false; }
                IntPtr p = GlobalLock(h);
                if (p == IntPtr.Zero) { GlobalFree(h); return false; }
                try {
                    Marshal.Copy(text.ToCharArray(), 0, p, text.Length);
                    Marshal.WriteInt16(p, text.Length * 2, 0);
                } finally { GlobalUnlock(h); }
                if (!SetClipboardData(CF_UNICODETEXT, h)) {
                    GlobalFree(h);
                    return false;
                }
                return true;
            } finally { CloseClipboard(); }
        }
        return false;
    }
}
'@

# ---- single instance guard -------------------------------------------------
try {
    $script:Lock = [System.IO.File]::Open($lockFile, 'OpenOrCreate', 'ReadWrite', 'None')
} catch {
    Write-Log 'another agent instance is already running, exit'
    exit 0
}

# ---- audio helpers ---------------------------------------------------------
# wsl.exe can block for a long time while the WSL VM is starting/stopping, so
# every call runs in a background job with a hard timeout: the clipboard loop
# (and the heartbeat) must never freeze because of an audio check.
$audioHealthCmd = 'export XDG_RUNTIME_DIR=/run/user/$(id -u); LC_ALL=C timeout 5 pactl -s unix:/mnt/wslg/PulseServer info >/dev/null 2>&1 && echo AUDIO_OK || echo AUDIO_FAIL'

function Invoke-WslEx {
    param([string[]]$WslArgs, [int]$TimeoutSec = 30)
    $job = $null
    try {
        $job = Start-Job -ScriptBlock { param($a) & wsl.exe @a } -ArgumentList (,$WslArgs)
        $done = Wait-Job -Job $job -Timeout $TimeoutSec
        if ($null -ne $done) {
            $out = Receive-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            return ($out -join "`n")
        }
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        return $null
    } catch { return $null }
}

# $true = healthy, $false = wedged, $null = no answer (WSL busy/not running)
function Test-WslgAudio {
    $out = Invoke-WslEx -WslArgs @('-d', $Distro, '--', 'bash', '-lc', $audioHealthCmd) -TimeoutSec 30
    if ($null -eq $out) { return $null }
    if ($out -match 'AUDIO_OK') { return $true }
    if ($out -match 'AUDIO_FAIL') { return $false }
    return $null
}

function Get-WslRunningList {
    return Invoke-WslEx -WslArgs @('--list', '--running') -TimeoutSec 20
}

function Repair-WslgAudio {
    Write-Log 'audio wedged (PulseAudio refused connections) - hot restart'
    Invoke-WslEx -WslArgs @('-d', $Distro, '--', 'bash', '-lc', 'pkill -f gnome-control-center 2>/dev/null; true') -TimeoutSec 30 | Out-Null
    Invoke-WslEx -WslArgs @('--system', '--', 'sh', '-c', 'pkill -9 pulseaudio') -TimeoutSec 30 | Out-Null
    for ($i = 0; $i -lt 7; $i++) {
        Start-Sleep -Seconds 3
        $state = Test-WslgAudio
        if ($state -eq $true) {
            Write-Log 'audio recovered after hot restart (no wsl --shutdown needed)'
            return $true
        }
        if ($null -eq $state) { Write-Log 'audio check got no answer while repairing (WSL busy?)' }
    }
    Write-Log 'audio still wedged after hot restart - run: wsl --shutdown, then start the desktop again'
    return $false
}

# ---- start ----------------------------------------------------------------
try {
    if ((Get-Item -LiteralPath $logFile -ErrorAction SilentlyContinue).Length -gt $MaxLogBytes) {
        Move-Item -LiteralPath $logFile -Destination ($logFile + '.old') -Force -ErrorAction SilentlyContinue
    }
} catch { }
Write-Log ('agent start (pid={0}, distro={1}, share={2})' -f $PID, $Distro, $ShareDir)

$lastWin  = $null
$lastReq  = Read-TextFile $reqFile
$initial  = [WslClip]::GetText()
if ($null -ne $initial -and $initial.Length -gt 0) {
    Write-TextFile $winFile $initial | Out-Null
    $lastWin = $initial
}

$lastHeartbeat = [DateTime]::MinValue
$nextAudio     = (Get-Date).AddSeconds(3)
$script:audioFailures = 0
$script:audioJob = $null
$script:audioJobStart = $null

while ($true) {
    # --- clipboard: Windows -> file ---------------------------------------
    $w = [WslClip]::GetText()
    if ($null -ne $w) {
        if ($w -ne $lastWin) {
            $lastWin = $w
            if ($w.Length -gt 0) {
                if ((Read-TextFile $winFile) -ne $w) {
                    if (Write-TextFile $winFile $w) { Write-Log ('win -> linux ({0} chars)' -f $w.Length) }
                }
            }
        }
        # --- clipboard: file -> Windows -----------------------------------
        $r = Read-TextFile $reqFile
        if ($null -ne $r -and $r -ne $lastReq) {
            $lastReq = $r
            if ($r.Length -gt 0 -and $r -ne $lastWin) {
                if ([WslClip]::SetText($r)) {
                    $lastWin = $r
                    Write-Log ('linux -> win ({0} chars)' -f $r.Length)
                }
            }
        }
    }

    # --- heartbeat --------------------------------------------------------
    if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge 1) {
        Write-TextFile $hbFile (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Out-Null
        $lastHeartbeat = Get-Date
    }

    # --- audio watchdog (async: the clipboard loop must stay responsive) ---
    if (-not $NoAudioWatch -and $null -eq $script:audioJob -and (Get-Date) -ge $nextAudio) {
        try {
            $script:audioJob = Start-Job -ScriptBlock {
                param($d, $c)
                $run = (& wsl.exe --list --running 2>$null) -join ' '
                if ($run -match [regex]::Escape($d)) {
                    & wsl.exe -d $d -- bash -lc $c 2>$null
                } else {
                    'NORUN'
                }
            } -ArgumentList $Distro, $audioHealthCmd
            $script:audioJobStart = Get-Date
        } catch {
            Write-Log ('audio check job failed to start: ' + $_.Exception.Message)
            $nextAudio = (Get-Date).AddSeconds($AudioCheckSec)
        }
    }

    if ($null -ne $script:audioJob) {
        $jobState = $script:audioJob.State
        $tooLong = ((Get-Date) - $script:audioJobStart).TotalSeconds -gt 120
        if ($jobState -eq 'Completed') {
            $out = ''
            try { $out = (Receive-Job -Job $script:audioJob -ErrorAction SilentlyContinue) -join "`n" } catch { }
            Remove-Job -Job $script:audioJob -Force -ErrorAction SilentlyContinue
            $script:audioJob = $null
            $nextAudio = (Get-Date).AddSeconds($AudioCheckSec)
            if ($out -match 'AUDIO_OK') {
                $script:audioFailures = 0
            } elseif ($out -match 'AUDIO_FAIL') {
                if (-not $script:audioFailures) { $script:audioFailures = 0 }
                $script:audioFailures = $script:audioFailures + 1
                Write-Log ('audio FAIL (consecutive={0})' -f $script:audioFailures)
                if (Repair-WslgAudio) { $script:audioFailures = 0 }
            } elseif ($out -match 'NORUN') {
                # WSL is stopped - nothing to check
            } else {
                Write-Log 'audio check got no answer (WSL busy) - retry next round'
            }
        } elseif ($jobState -eq 'Failed' -or $tooLong) {
            Write-Log 'audio check job failed/timed out - retry next round'
            Stop-Job -Job $script:audioJob -ErrorAction SilentlyContinue
            Remove-Job -Job $script:audioJob -Force -ErrorAction SilentlyContinue
            $script:audioJob = $null
            $nextAudio = (Get-Date).AddSeconds($AudioCheckSec)
        }
    }

    Start-Sleep -Milliseconds $PollMs
}
