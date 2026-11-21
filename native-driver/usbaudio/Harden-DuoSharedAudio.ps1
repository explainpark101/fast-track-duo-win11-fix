#Requires -Version 5.1
<#
.SYNOPSIS
  Reduce intermittent per-app silence on Fast Track Duo (Firefox/Chrome shared mode).

.DESCRIPTION
  Symptom: one browser goes silent; another app starting audio "unsticks" it.
  Typical causes on Duo under usbaudio:
    1) Exclusive-mode preemption of shared WASAPI graphs
    2) Leftover SysFx / FX attach races
    3) Stale Audio Engine mix after multi-client churn

  This script (elevated):
    - Disables exclusive mode + exclusive priority on Duo render/capture endpoints
    - Disables SysFx / blanks FX CLSIDs (same approach as Install-UsbAudio)
    - Restarts Windows Audio (Audiosrv) + AudioEndpointBuilder
#>
[CmdletBinding()]
param(
  [switch]$SkipAudioServiceRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$UsbVidPid = 'VID_0B0F&PID_2036'
$NameRegex = 'Fast Track Duo|Avid Fast Track Duo|USB Audio Class'

# Sound CPL "Allow exclusive" / "Give exclusive priority"
$ExclusiveAllow = '{b3f8fa53-0004-438e-9003-51a46e139bfc},3'
$ExclusivePriority = '{b3f8fa53-0004-438e-9003-51a46e139bfc},4'
$SysFxDisable = '{1da5d803-d492-4edd-8c23-e0c0ffee7f0e},5'
$FxKeys = @(
  '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},0',
  '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},1',
  '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},2',
  '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},3',
  '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},4'
)
$NullGuid = '{00000000-0000-0000-0000-000000000000}'

function Write-Step([string]$m) { Write-Host ""; Write-Host "=== $m ===" -ForegroundColor Cyan }

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
  # UAC cancel is almost always accidental — keep prompting until approved or hard fail.
  $maxTries = 5
  for ($try = 1; $try -le $maxTries; $try++) {
    Write-Host ("Elevating (UAC / PIN)... attempt {0}/{1}" -f $try, $maxTries)
    try {
      $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
      ) -PassThru -Wait -ErrorAction Stop
      exit $p.ExitCode
    } catch {
      Write-Host 'UAC was cancelled or elevation failed. Requesting again...'
      Start-Sleep -Seconds 1
    }
  }
  throw 'Elevation failed after repeated UAC prompts. Approve the UAC dialog (PIN OK).'
}

function Test-DuoEndpointProps($props) {
  if ($null -eq $props) { return $false }
  $blob = @($props.PSObject.Properties | ForEach-Object { [string]$_.Value }) -join ' '
  return ($blob -match $NameRegex -or $blob -match $UsbVidPid)
}

function Invoke-SystemWorker {
  $worker = Join-Path $PSScriptRoot 'Harden-DuoSharedAudio-SystemWorker.ps1'
  if (-not (Test-Path -LiteralPath $worker)) { throw "missing $worker" }
  $logDir = Join-Path $PSScriptRoot 'logs'
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null
  $out = Join-Path $logDir 'harden-system-worker.log'
  $cmd = Join-Path $logDir 'run-harden-system.cmd'
  @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$worker" > "$out" 2>&1
"@ | Set-Content -LiteralPath $cmd -Encoding ASCII
  Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue

  $task = 'FtdDuoHardenShared'
  Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
  # /TR must stay short; use tiny .cmd wrapper
  $action = New-ScheduledTaskAction -Execute $cmd
  $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  # ONCE + far future start — we Start-ScheduledTask immediately
  $trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddYears(1))
  Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Trigger $trigger -Force | Out-Null
  Start-ScheduledTask -TaskName $task
  $deadline = (Get-Date).AddSeconds(90)
  do {
    Start-Sleep -Milliseconds 500
    $state = (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue).State
  } while ($state -eq 'Running' -and (Get-Date) -lt $deadline)
  Start-Sleep 1
  Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $out) {
    Get-Content -LiteralPath $out | ForEach-Object { Write-Host $_ }
  } else {
    Write-Host 'WARNING: SYSTEM worker produced no log'
  }
}

Write-Step 'Disable exclusive mode + SysFx via MMDevice PropertyStore'
$exclusive = Join-Path $PSScriptRoot 'Set-DuoExclusiveOff.ps1'
& $exclusive
if ($LASTEXITCODE -ne 0) {
  Write-Host 'PropertyStore path failed; trying SYSTEM registry worker fallback...'
  Invoke-SystemWorker
}

Write-Step 'Strip DeviceClasses FX\\0 for Duo (best effort)'
$dcRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\{6994ad04-93ef-11d0-a3cc-00a0c9223196}'
if (Test-Path $dcRoot) {
  Get-ChildItem $dcRoot -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -like "*$UsbVidPid*" } |
    ForEach-Object {
      Get-ChildItem -LiteralPath $_.PSPath -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.PSPath -match '\\FX\\0$' -or $_.PSChildName -eq 'MSFX' } |
        Sort-Object { $_.PSPath.Length } -Descending |
        ForEach-Object {
          try {
            Remove-Item -LiteralPath $_.PSPath -Recurse -Force -ErrorAction Stop
            Write-Host ("removed " + $_.PSPath)
          } catch {
            Write-Host ("FX strip skipped: " + $_.Exception.Message)
          }
        }
    }
}

if (-not $SkipAudioServiceRestart) {
  Write-Step 'Restart Windows Audio services'
  foreach ($svc in @('Audiosrv', 'AudioEndpointBuilder')) {
    try {
      Restart-Service -Name $svc -Force -ErrorAction Stop
      Write-Host "Restarted $svc"
    } catch {
      Write-Host ("{0}: {1}" -f $svc, $_.Exception.Message)
      & net.exe stop $svc /y 2>&1 | Out-Null
      Start-Sleep 1
      & net.exe start $svc 2>&1 | Out-Null
    }
  }
}

Write-Host ''
Write-Host 'Done. Retest: Firefox YouTube + Chrome media. Keep Spatial sound Off on Duo.'
Write-Host 'Also keep Intel SST for USB Audio disabled (Disable-IntelSstUsb.cmd).'
exit 0
