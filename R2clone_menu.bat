@echo off
title R2clone menu
chcp 65001 >nul
cd /d "%~dp0"
echo Starting R2clone menu...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0R2clone_menu.ps1" %*
if errorlevel 1 (
    echo.
    echo PowerShell exited with code %errorlevel%.
    pause
)
exit /b
