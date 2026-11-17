@echo off
setlocal
:: One-click Fast Track Duo patch (UAC elevation)
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Patch.ps1"
echo.
pause
endlocal
