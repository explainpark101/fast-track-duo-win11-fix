$ErrorActionPreference='Continue'
Start-Transcript -Path 'C:\Users\jaehy\.t3\projects\fast-track-duo-fix\native-driver\usbaudio\logs\exclusive-off.log' -Force
try { & 'C:\Users\jaehy\.t3\projects\fast-track-duo-fix\native-driver\usbaudio\Set-DuoExclusiveOff.ps1'; $code=$LASTEXITCODE } catch { Write-Host $_; $code=1 }
Stop-Transcript
exit $code
