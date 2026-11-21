@echo off
setlocal
cd /d "%~dp0"
REM Triggers UAC. Approve with PIN if Windows offers it.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Sign-And-Install-SoftVol.ps1" %*
exit /b %ERRORLEVEL%
