@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Users\jaehy\.t3\projects\fast-track-duo-fix\native-driver\usbaudio\Harden-DuoSharedAudio-SystemWorker.ps1" > "C:\Users\jaehy\.t3\projects\fast-track-duo-fix\native-driver\usbaudio\logs\harden-system-worker.log" 2>&1
