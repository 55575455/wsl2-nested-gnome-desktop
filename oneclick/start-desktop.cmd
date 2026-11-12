@echo off
rem One-click launcher for the WSL nested GNOME desktop (background start).
rem This file uses %~dp0, so it works from ANY current directory (and by double-click).
rem Usage: double-click this file, or run:
rem   start-desktop.cmd -Status   (show status)
rem   start-desktop.cmd -Stop     (stop desktop)
rem   start-desktop.cmd -Wait     (wait until the desktop window appears)
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-desktop.ps1" %*
if errorlevel 1 pause
endlocal
