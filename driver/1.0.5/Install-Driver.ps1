#Requires -Version 5.1
<#
.SYNOPSIS
  Full reinstall: remove stock 1.0.4 package pieces, install community 1.0.5 INF+SYS.

.DESCRIPTION
  Product: Fast-Track-Duo-Driver_fix.1.0.0
  - Uninstalls existing Duo MEDIA device driver packages
  - Adds driver\1.0.5 (nofx INF + original Avid .sys)
  - Strips leftover Home Theater FX keys
  Requires elevation. Modified INF has no .cat; Windows may require
  testsigning / Memory Integrity off for package install.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$InfPath = Join-Path $ScriptDir 'AvidFastTrackDuo.inf'
$SysPath = Join-Path $ScriptDir 'AvidFastTrackDuo.sys'
$LogDir = Join-Path $ScriptDir 'logs'
$LogFile = Join-Path $LogDir ('driver-install-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))

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
  Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath
  ) | Out-Null
  exit 0
}

function Invoke-SystemScript([string]$LauncherPath) {
  $task = 'FastTrackDuoDriverInstall'
  $tr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $LauncherPath + '"'
  & schtasks.exe /Delete /TN $task /F 2>$null | Out-Null
  & schtasks.exe /Create /TN $task /RU SYSTEM /RL HIGHEST /SC ONCE /ST 23:59 /TR $tr /F | Out-Null
  & schtasks.exe /Run /TN $task | Out-Null
  $deadline = (Get-Date).AddSeconds(180)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    if (Test-Path -LiteralPath $LogFile) {
      $tail = Get-Content -LiteralPath $LogFile -Tail 8 -ErrorAction SilentlyContinue
      if ($tail -match 'WORKER_DONE') { break }
    }
  }
  & schtasks.exe /Delete /TN $task /F 2>$null | Out-Null
}

Request-Elevation

if (-not (Test-Path -LiteralPath $InfPath)) { throw "Missing INF: $InfPath" }
if (-not (Test-Path -LiteralPath $SysPath)) { throw "Missing SYS: $SysPath" }

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Write-Log 'Fast-Track-Duo-Driver_fix.1.0.0 / driver 1.0.5 install starting'

$workerPath = Join-Path $LogDir 'system-worker.ps1'
@'
param(
  [Parameter(Mandatory=$true)][string]$InfPath,
  [Parameter(Mandatory=$true)][string]$LogFile,
  [Parameter(Mandatory=$true)][string]$UsbVidPid,
  [Parameter(Mandatory=$true)][string]$AudioClassGuid,
  [Parameter(Mandatory=$true)][string]$NameRegex
)

$ErrorActionPreference = "Continue"
function L([string]$m) {
  Add-Content -LiteralPath $LogFile -Value ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m) -Encoding UTF8
}

L ("whoami=" + [Security.Principal.WindowsIdentity]::GetCurrent().Name)
L ("INF=" + $InfPath)

# Remove existing Duo devices
Get-PnpDevice -ErrorAction SilentlyContinue |
  Where-Object { $_.InstanceId -like ("USB\{0}*" -f $UsbVidPid) } |
  ForEach-Object {
    try {
      Disable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
      Remove-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
      L ("removed device " + $_.InstanceId)
    } catch { L ("device remove: " + $_.Exception.Message) }
  }

# Delete published driver packages for this INF name
try {
  $drivers = & pnputil.exe /enum-drivers
  $block = $drivers -join "`n"
  $matches = [regex]::Matches($block, '(?ms)Published Name:\s+(oem\d+\.inf).*?Original Name:\s+(AvidFastTrackDuo\.inf)')
  foreach ($m in $matches) {
    $oem = $m.Groups[1].Value
    L ("deleting package " + $oem)
    & pnputil.exe /delete-driver $oem /uninstall /force 2>&1 | ForEach-Object { L ($_ | Out-String).Trim() }
  }
} catch { L ("pnputil enum/delete: " + $_.Exception.Message) }

# Also wipe old DriverStore folders for stock INF so they do not win ranking
Get-ChildItem "C:\Windows\System32\DriverStore\FileRepository" -Directory -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -like "avidfasttrackduo.inf_*" } |
  ForEach-Object {
    try {
      takeown /f $_.FullName /r /d Y | Out-Null
      icacls $_.FullName /grant "*S-1-5-32-544:F" /T | Out-Null
      Remove-Item -LiteralPath $_.FullName -Recurse -Force
      L ("removed DriverStore " + $_.Name)
    } catch { L ("DriverStore wipe fail: " + $_.Exception.Message) }
  }

# Add + install 1.0.5 package
L "pnputil /add-driver ..."
$add = & pnputil.exe /add-driver $InfPath /install 2>&1
$add | ForEach-Object { L (($_ | Out-String).Trim()) }

# Strip FX leftovers
$dcRoot = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\$AudioClassGuid"
if (Test-Path $dcRoot) {
  Get-ChildItem $dcRoot -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -like "*$UsbVidPid*" } |
    ForEach-Object {
      Get-ChildItem -LiteralPath $_.PSPath -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.PSPath -match '\\FX\\0$' -or $_.PSChildName -eq 'MSFX' } |
        Sort-Object { $_.PSPath.Length } -Descending |
        ForEach-Object {
          try { Remove-Item -LiteralPath $_.PSPath -Recurse -Force; L ("removed " + $_.PSPath) }
          catch { L ("FX strip: " + $_.Exception.Message) }
        }
    }
}

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
    if (-not (Test-Path -LiteralPath $fxPath)) { New-Item -Path $fxPath -Force | Out-Null }
    try {
      Set-ItemProperty -LiteralPath $fxPath -Name $sysfx -Value 1 -Type DWord -Force
      Set-ItemProperty -LiteralPath $fxPath -Name $fxKeys[4] -Value "" -Force -ErrorAction SilentlyContinue
      for ($i = 0; $i -le 3; $i++) {
        Set-ItemProperty -LiteralPath $fxPath -Name $fxKeys[$i] -Value $nullGuid -Force -ErrorAction SilentlyContinue
      }
      L ("SysFx disabled " + $_.PSChildName)
    } catch { L ("MMDevices: " + $_.Exception.Message) }
  }
}

try {
  Restart-Service -Name Audiosrv,AudioEndpointBuilder -Force -ErrorAction Stop
  L "audio services restarted"
} catch { L ("audio restart: " + $_.Exception.Message) }

# Rescan PnP
try { & pnputil.exe /scan-devices 2>&1 | ForEach-Object { L (($_ | Out-String).Trim()) } } catch {}

L "WORKER_DONE"
'@ | Set-Content -LiteralPath $workerPath -Encoding UTF8

$launcherPath = Join-Path $LogDir 'launch-worker.ps1'
$launch = @(
  "& `"$workerPath`""
  "-InfPath `"$InfPath`""
  "-LogFile `"$LogFile`""
  "-UsbVidPid `"$UsbVidPid`""
  "-AudioClassGuid `"$AudioClassGuid`""
  "-NameRegex `"$NameRegex`""
) -join ' '
Set-Content -LiteralPath $launcherPath -Value $launch -Encoding UTF8

Write-Log 'Running SYSTEM worker (uninstall + install 1.0.5)...'
Invoke-SystemScript -LauncherPath $launcherPath

Write-Host ''
Write-Host '---- log tail ----'
if (Test-Path -LiteralPath $LogFile) { Get-Content -LiteralPath $LogFile -Tail 60 }

Write-Host ''
Write-Host 'Done. If pnputil rejected the package (signature):'
Write-Host '  - Turn off Memory Integrity, or enable testsigning, then re-run'
Write-Host '  - Or use 1.0.4-patch.exe on top of the official 1.0.4 install instead'
Write-Host 'Then: Spatial sound Off + Enhancements Disable all'
Write-Host ("Log: $LogFile")
