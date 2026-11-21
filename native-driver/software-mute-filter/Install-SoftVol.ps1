#Requires -Version 5.1
<#
.SYNOPSIS
  Install FtdSoftVol upper filter + inbox usbaudio for Fast Track Duo.

.DESCRIPTION
  Prototype path: bind MI_00 to usbaudio.sys and load FtdSoftVol.sys as an
  UpperFilter so Windows uses software mute/volume (hides hardware VOLUME/MUTE
  KS nodes). Requires a built FtdSoftVol.sys next to the INF (see README).

  Typical flow:
    1) Build + test-sign FtdSoftVol.sys (WDK)
    2) bcdedit /set testsigning on  (reboot)   — development only
    3) Run this script elevated
#>

[CmdletBinding()]
param(
  [string]$SysPath,
  [switch]$AllowRebootPrompt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$InfPath = Join-Path $ScriptDir 'inf\FtdSoftVol.inf'
$PackageDir = Join-Path $ScriptDir 'package'
$UsbVidPid = 'VID_0B0F&PID_2036'

function Write-Log([string]$Message) {
  Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message)
}

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-Elevation {
  if (Test-IsAdmin) { return }
  Write-Host 'Administrator rights required. Re-launching elevated...'
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
  if ($SysPath) { $argList += @('-SysPath', "`"$SysPath`"") }
  if ($AllowRebootPrompt) { $argList += '-AllowRebootPrompt' }
  Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList | Out-Null
  exit 0
}

function Find-BuiltSys {
  if ($SysPath -and (Test-Path -LiteralPath $SysPath)) {
    return (Resolve-Path -LiteralPath $SysPath).Path
  }
  $candidates = @(
    (Join-Path $ScriptDir 'package\FtdSoftVol.sys'),
    (Join-Path $ScriptDir 'Release\x64\FtdSoftVol.sys'),
    (Join-Path $ScriptDir 'Debug\x64\FtdSoftVol.sys'),
    (Join-Path $ScriptDir 'x64\Release\FtdSoftVol.sys'),
    (Join-Path $ScriptDir 'x64\Debug\FtdSoftVol.sys')
  )
  foreach ($c in $candidates) {
    if (Test-Path -LiteralPath $c) { return (Resolve-Path -LiteralPath $c).Path }
  }
  return $null
}

Request-Elevation

if (-not (Test-Path -LiteralPath $InfPath)) {
  throw "INF not found: $InfPath"
}

$sys = Find-BuiltSys
if (-not $sys) {
  throw @"
FtdSoftVol.sys not found.
Build with WDK (FtdSoftVol.sln, Release|x64), test-sign the .sys, then either:
  - copy it to $PackageDir\FtdSoftVol.sys
  - or pass -SysPath path\to\FtdSoftVol.sys
"@
}

New-Item -ItemType Directory -Force -Path $PackageDir | Out-Null
Copy-Item -LiteralPath $sys -Destination (Join-Path $PackageDir 'FtdSoftVol.sys') -Force
Copy-Item -LiteralPath $InfPath -Destination (Join-Path $PackageDir 'FtdSoftVol.inf') -Force

Write-Log "Package: $PackageDir"
Write-Log "Sys: $sys"

$testSigning = (bcdedit /enum '{current}' 2>$null | Out-String)
if ($testSigning -notmatch 'testsigning\s+Yes') {
  Write-Log 'WARNING: testsigning does not appear enabled. Unsigned/test-signed kernel drivers need it (or WHCP).'
}

Write-Log 'pnputil /add-driver FtdSoftVol.inf /install'
$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$out = & pnputil.exe /add-driver (Join-Path $PackageDir 'FtdSoftVol.inf') /install 2>&1
$ErrorActionPreference = $prev
$out | ForEach-Object { Write-Log ($_ | Out-String).Trim() }

$devs = Get-PnpDevice -ErrorAction SilentlyContinue |
  Where-Object { $_.InstanceId -like ("USB\{0}&MI_00*" -f $UsbVidPid) }

foreach ($d in $devs) {
  $svc = (Get-PnpDeviceProperty -InstanceId $d.InstanceId |
    Where-Object KeyName -eq 'DEVPKEY_Device_Service').Data
  $filters = $null
  try {
    $key = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.InstanceId)"
    $filters = (Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).UpperFilters
  } catch { }
  Write-Log ("Device {0} Service={1} UpperFilters={2}" -f $d.InstanceId, $svc, ($filters -join ','))
}

Write-Log 'Done. Run Verify-SoftVol.ps1. Mute test: play audio, toggle Windows mute.'
if ($AllowRebootPrompt) {
  $r = Read-Host 'Reboot now so the filter attaches cleanly? [y/N]'
  if ($r -match '^[yY]') { shutdown.exe /r /t 0 }
}
