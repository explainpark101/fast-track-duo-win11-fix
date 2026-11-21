#Requires -Version 5.1
<#
.SYNOPSIS
  Disable "Intel Smart Sound Technology for USB Audio" so Duo uses usbaudio
  (+ FtdSoftVol) instead of the Intel SST proxy that ignores Windows volume/mute.

.DESCRIPTION
  On many Intel 11th-gen+ laptops, IntcUSB / SST wraps USB audio endpoints.
  Windows mute/volume then hit the Intel topology, not usbaudio — so FtdSoftVol
  on the USB stack cannot help. Disabling SST USB Audio is the vendor-documented
  workaround (Audio-Technica, AudioQuest, Dell, etc.).
#>
[CmdletBinding()]
param(
  [switch]$Reboot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
  Write-Host 'Elevating (UAC / PIN)...'
  Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
    $(if ($Reboot) { '-Reboot' } else { '' })
  ).Where({ $_ }) -Wait
  exit 0
}

Write-Host '=== Finding Intel SST USB Audio devices ==='
$targets = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
  ($_.InstanceId -match 'INTELAUDIO\\.*LINKTYPE_06') -or
  ($_.FriendlyName -match 'Smart Sound Technology for USB|USB.*스마트 사운드|USB 오디오용 인텔')
}

if (-not $targets) {
  Write-Host 'No Intel SST USB Audio device found (already gone or different OEM name).'
  exit 0
}

foreach ($d in $targets) {
  Write-Host ("Target: {0}" -f $d.FriendlyName)
  Write-Host ("  Id:   {0}  Status={1}" -f $d.InstanceId, $d.Status)

  $key = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.InstanceId)"
  if (Test-Path -LiteralPath $key) {
    # CONFIGFLAG_DISABLED = 0x1 — survives until explicitly enabled
    New-ItemProperty -LiteralPath $key -Name 'ConfigFlags' -PropertyType DWord -Value 1 -Force | Out-Null
    Write-Host '  Set ConfigFlags=1 (disabled)'
  }

  try {
    Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop
    Write-Host '  Disable-PnpDevice: OK'
  } catch {
    Write-Host ("  Disable-PnpDevice: {0}" -f $_.Exception.Message)
    Write-Host '  (If pending reboot, ConfigFlags still forces disable after reboot.)'
  }

  try {
    & pnputil.exe /disable-device $d.InstanceId 2>&1 | ForEach-Object { Write-Host "  $_" }
  } catch { }
}

Write-Host ''
Write-Host 'Next: reboot if the device still shows OK, then Verify-SoftVol.ps1 and test Windows mute.'
if ($Reboot) {
  Write-Host 'Rebooting in 5 seconds...'
  Start-Sleep 5
  shutdown.exe /r /t 0
}
exit 0
