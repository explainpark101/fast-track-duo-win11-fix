@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-BuildTools.ps1" %*
exit /b %ERRORLEVEL%
