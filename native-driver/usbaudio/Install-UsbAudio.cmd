@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-UsbAudio.ps1" %*
exit /b %ERRORLEVEL%
