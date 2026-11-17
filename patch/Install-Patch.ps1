#Requires -Version 5.1
<#
.SYNOPSIS
  One-click Fast Track Duo hardening patch for Windows 10/11.

.DESCRIPTION
  - Replaces DriverStore / published oem INF with AvidFastTrackDuo.nofx.inf
  - Strips DeviceClasses FX\0 and MSFX for USB\VID_0B0F&PID_2036
  - Disables SysFx on Duo endpoints found by friendly name
  - Restarts audio services and the Duo MEDIA device

  Does not modify AvidFastTrackDuo.sys.
  Discovers machine-specific INF names, DeviceClasses nodes, and endpoint
  GUIDs at runtime (nothing host-specific is hard-coded).
#>

[CmdletBinding()]
param(
  [switch]$SkipDeviceRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$NofxInf = Join-Path $ScriptDir 'AvidFastTrackDuo.nofx.inf'
$LogDir = Join-Path $ScriptDir 'logs'
$LogFile = Join-Path $LogDir ('install-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))

$UsbVidPid = 'VID_0B0F&PID_2036'
$AudioClassGuid = '{6994ad04-93ef-11d0-a3cc-00a0c9223196}'
$NameRegex = 'Fast Track Duo|Avid Fast Track Duo'

function Write-Log([string]$Message) {
  $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Write-Host $line
  Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-Elevation {
  if (Test-IsAdmin) { return }
  Write-Host 'Administrator rights required. Re-launching elevated...'
  $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
  if ($SkipDeviceRestart) { $args += '-SkipDeviceRestart' }
  Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $args | Out-Null
  exit 0
}

function Invoke-SystemScript([string]$LauncherPath) {
  $task = 'FastTrackDuoInstallPatch'
  $tr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $LauncherPath + '"'
  & schtasks.exe /Delete /TN $task /F 2>$null | Out-Null
  & schtasks.exe /Create /TN $task /RU SYSTEM /RL HIGHEST /SC ONCE /ST 23:59 /TR $tr /F | Out-Null
  & schtasks.exe /Run /TN $task | Out-Null

  $deadline = (Get-Date).AddSeconds(120)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    if (Test-Path -LiteralPath $LogFile) {
      $tail = Get-Content -LiteralPath $LogFile -Tail 5 -ErrorAction SilentlyContinue
      if ($tail -match 'WORKER_DONE') { break }
    }
  }
  & schtasks.exe /Delete /TN $task /F 2>$null | Out-Null
}

Request-Elevation

if (-not (Test-Path -LiteralPath $NofxInf)) {
  throw "Missing nofx INF: $NofxInf"
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Write-Log 'Fast Track Duo patch install starting'

# Worker runs as SYSTEM so ACL-locked MMDevices / INF files can be updated.
$workerPath = Join-Path $LogDir 'system-worker.ps1'
$worker = @'
param(
  [Parameter(Mandatory=$true)][string]$NofxInf,
  [Parameter(Mandatory=$true)][string]$LogFile,
  [Parameter(Mandatory=$true)][string]$UsbVidPid,
  [Parameter(Mandatory=$true)][string]$AudioClassGuid,
  [Parameter(Mandatory=$true)][string]$NameRegex,
  [bool]$SkipDeviceRestart = $false
)

$ErrorActionPreference = "Continue"
function L([string]$m) {
  Add-Content -LiteralPath $LogFile -Value ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m) -Encoding UTF8
}

L ("whoami=" + [Security.Principal.WindowsIdentity]::GetCurrent().Name)

# 1) DriverStore INF
Get-ChildItem "C:\Windows\System32\DriverStore\FileRepository" -Directory -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -like "avidfasttrackduo.inf_*" } |
  ForEach-Object {
    $dst = Join-Path $_.FullName "AvidFastTrackDuo.inf"
    $pnf = Join-Path $_.FullName "AvidFastTrackDuo.PNF"
    if (Test-Path -LiteralPath $dst) {
      try {
        takeown /f $dst /a | Out-Null
        icacls $dst /grant "*S-1-5-32-544:F" "SYSTEM:F" | Out-Null
        Copy-Item -LiteralPath $NofxInf -Destination $dst -Force
        L ("patched DriverStore: " + $_.Name)
      } catch { L ("DriverStore fail: " + $_.Exception.Message) }
    }
    if (Test-Path -LiteralPath $pnf) {
      try {
        takeown /f $pnf /a | Out-Null
        Remove-Item -LiteralPath $pnf -Force
        L ("removed PNF: " + $_.Name)
      } catch { L ("PNF fail: " + $_.Exception.Message) }
    }
  }

# 2) Published oem*.inf that mention this device
Get-ChildItem "C:\Windows\INF\oem*.inf" -ErrorAction SilentlyContinue | ForEach-Object {
  $text = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue
  if ($null -eq $text) { return }
  if ($text -notmatch [regex]::Escape($UsbVidPid) -and $text -notmatch "Fast Track Duo" -and $text -notmatch "AvidFastTrackDuo") {
    return
  }
  try {
    takeown /f $_.FullName /a | Out-Null
    icacls $_.FullName /grant "*S-1-5-32-544:F" "SYSTEM:F" | Out-Null
    Copy-Item -LiteralPath $NofxInf -Destination $_.FullName -Force
    L ("patched published INF: " + $_.Name)
    $pnf = [IO.Path]::ChangeExtension($_.FullName, ".PNF")
    if (Test-Path -LiteralPath $pnf) {
      takeown /f $pnf /a | Out-Null
      Remove-Item -LiteralPath $pnf -Force
      L ("removed " + [IO.Path]::GetFileName($pnf))
    }
  } catch { L ("oem fail $($_.Name): " + $_.Exception.Message) }
}

# 3) DeviceClasses FX\0 / MSFX
$dcRoot = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\$AudioClassGuid"
if (Test-Path $dcRoot) {
  Get-ChildItem $dcRoot -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -like "*$UsbVidPid*" } |
    ForEach-Object {
      L ("DeviceClasses: " + $_.PSChildName)
      Get-ChildItem -LiteralPath $_.PSPath -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
          $_.PSPath -match '\\FX\\0$' -or
          $_.PSPath -match '\\MSFX$' -or
          ($_.PSChildName -eq "MSFX")
        } |
        Sort-Object { $_.PSPath.Length } -Descending |
        ForEach-Object {
          try {
            Remove-Item -LiteralPath $_.PSPath -Recurse -Force
            L ("removed " + $_.PSPath)
          } catch {
            L ("strip fail: " + $_.Exception.Message)
          }
        }
    }
} else {
  L "DeviceClasses root missing"
}

# 4) MMDevices render endpoints by name
$fxKeys = @(
  "{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},0",
  "{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},1",
  "{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},2",
  "{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},3",
  "{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},4"
)
$nullGuid = "{00000000-0000-0000-0000-000000000000}"
$sysfx = "{1da5d803-d492-4edd-8c23-e0c0ffee7f0e},5"
$renderRoot = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render"

if (Test-Path $renderRoot) {
  Get-ChildItem $renderRoot -ErrorAction SilentlyContinue | ForEach-Object {
    $propsPath = Join-Path $_.PSPath "Properties"
    if (-not (Test-Path -LiteralPath $propsPath)) { return }
    $props = Get-ItemProperty -LiteralPath $propsPath -ErrorAction SilentlyContinue
    $blob = @($props.PSObject.Properties | ForEach-Object { [string]$_.Value }) -join " "
    if ($blob -notmatch $NameRegex) { return }

    $fxPath = Join-Path $_.PSPath "FxProperties"
    if (-not (Test-Path -LiteralPath $fxPath)) {
      New-Item -Path $fxPath -Force | Out-Null
    }
    try {
      Set-ItemProperty -LiteralPath $fxPath -Name $sysfx -Value 1 -Type DWord -Force
      Set-ItemProperty -LiteralPath $fxPath -Name $fxKeys[4] -Value "" -Force -ErrorAction SilentlyContinue
      for ($i = 0; $i -le 3; $i++) {
        Set-ItemProperty -LiteralPath $fxPath -Name $fxKeys[$i] -Value $nullGuid -Force -ErrorAction SilentlyContinue
      }
      L ("SysFx disabled for render endpoint " + $_.PSChildName)
    } catch {
      L ("MMDevices fail: " + $_.Exception.Message)
    }
  }
}

# 5) Restart services / device
try {
  Restart-Service -Name Audiosrv,AudioEndpointBuilder -Force -ErrorAction Stop
  L "audio services restarted"
} catch {
  L ("audio restart: " + $_.Exception.Message)
}

if (-not $SkipDeviceRestart) {
  try {
    Get-PnpDevice -ErrorAction SilentlyContinue |
      Where-Object { $_.InstanceId -like ("USB\{0}*" -f $UsbVidPid) -and $_.Class -eq "MEDIA" } |
      ForEach-Object {
        Disable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Enable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
        L ("toggled " + $_.InstanceId)
      }
  } catch {
    L ("PnP: " + $_.Exception.Message)
  }
}

L "WORKER_DONE"
'@

Set-Content -LiteralPath $workerPath -Value $worker -Encoding UTF8

$launcherPath = Join-Path $LogDir 'launch-worker.ps1'
$skipLit = if ($SkipDeviceRestart) { '$true' } else { '$false' }
$launch = @(
  "& `"$workerPath`""
  "-NofxInf `"$NofxInf`""
  "-LogFile `"$LogFile`""
  "-UsbVidPid `"$UsbVidPid`""
  "-AudioClassGuid `"$AudioClassGuid`""
  "-NameRegex `"$NameRegex`""
  "-SkipDeviceRestart:$skipLit"
) -join ' '
Set-Content -LiteralPath $launcherPath -Value $launch -Encoding UTF8

Write-Log 'Running SYSTEM worker...'
Invoke-SystemScript -LauncherPath $launcherPath

Write-Host ''
Write-Host '---- log tail ----'
if (Test-Path -LiteralPath $LogFile) {
  Get-Content -LiteralPath $LogFile -Tail 50
}

Write-Host ''
Write-Host 'Done. Manual follow-up (once):'
Write-Host '  1) Settings > System > Sound > Avid Fast Track Duo > Spatial sound = Off'
Write-Host '  2) Sound Control Panel > Duo > Enhancements > Disable all'
Write-Host '  3) Prefer USB 2.0; re-run after major Windows updates if symptoms return'
Write-Host ("Log: $LogFile")
