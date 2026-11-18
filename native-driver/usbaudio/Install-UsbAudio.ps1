#Requires -Version 5.1
<#
.SYNOPSIS
  Replace Avid Fast Track Duo proprietary WDM driver with Microsoft usbaudio.sys.

.DESCRIPTION
  Duo has USB Audio Class 1.0 compatible IDs. Inbox wdma_usb.inf / usbaudio.sys
  already matches but is outranked by Avid's signed VID/PID package.

  Strategy (Windows 11 — no pnputil /update-driver on this OS):
    1) Force-delete Avid oem*.inf packages (case-insensitive name match)
    2) Install inbox DriverStore copy of wdma_usb.inf with /add-driver /install
    3) Re-enumerate MI_00; expect service = usbaudio
    4) Best-effort FX cleanup (MMDevices may be TrustedInstaller-locked)

  Unsigned OEM INF (FastTrackDuoUsbAudio.inf) is optional and usually rejected
  under Secure Boot / third-party INF policy — inbox path is the real fix.
#>

[CmdletBinding()]
param(
  # Try community OEM INF first (usually fails without a catalog).
  [switch]$TryOemInf,
  # After a failed bind, ask to reboot (pending file ops / driver delete).
  [switch]$AllowRebootPrompt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$OemInfPath = Join-Path $ScriptDir 'FastTrackDuoUsbAudio.inf'
$InboxInfRoot = Join-Path $env:SystemRoot 'INF\wdma_usb.inf'
$LogDir = Join-Path $ScriptDir 'logs'
$LogFile = Join-Path $LogDir ('usbaudio-install-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))

$UsbVidPid = 'VID_0B0F&PID_2036'
$AudioClassGuid = '{6994ad04-93ef-11d0-a3cc-00a0c9223196}'
$NameRegex = 'Fast Track Duo|Avid Fast Track Duo|USB Audio Class'

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
  $argList = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
  )
  if ($TryOemInf) { $argList += '-TryOemInf' }
  if ($AllowRebootPrompt) { $argList += '-AllowRebootPrompt' }
  Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList | Out-Null
  exit 0
}

function Invoke-PnpUtil {
  param([Parameter(Mandatory)][string[]]$Args)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & pnputil.exe @Args 2>&1
    foreach ($line in $out) {
      $t = ($line | Out-String).Trim()
      if ($t) { Write-Log $t }
    }
    return ($out | Out-String)
  } finally {
    $ErrorActionPreference = $prev
  }
}

function Get-InboxWdmaUsbInf {
  $repo = Get-ChildItem (Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository') `
    -Directory -Filter 'wdma_usb.inf*' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if ($repo) {
    $inf = Join-Path $repo.FullName 'wdma_usb.inf'
    if (Test-Path -LiteralPath $inf) { return $inf }
  }
  if (Test-Path -LiteralPath $InboxInfRoot) { return $InboxInfRoot }
  return $null
}

function Get-DuoMi00 {
  Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -like ("USB\{0}&MI_00*" -f $UsbVidPid) }
}

function Get-DuoService([string]$InstanceId) {
  return (Get-PnpDeviceProperty -InstanceId $InstanceId -ErrorAction SilentlyContinue |
    Where-Object KeyName -eq 'DEVPKEY_Device_Service').Data
}

function Remove-AvidPackages {
  Write-Log 'Enumerating OEM driver packages...'
  $raw = Invoke-PnpUtil -Args @('/enum-drivers')
  # Case-insensitive: published oem + original name
  # Keep newlines; match across blank spacing between fields.
  $rx = [regex]::new(
    'Published Name:\s+(oem\d+\.inf)\s+Original Name:\s+(\S+)',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
    [System.Text.RegularExpressions.RegexOptions]::Singleline)
  $targets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($m in $rx.Matches($raw)) {
    $oem = $m.Groups[1].Value
    $orig = $m.Groups[2].Value.Trim()
    if ($orig -match '(?i)avidfasttrackduo|fasttrackduousbaudio|fasttrackduonew') {
      [void]$targets.Add($oem)
      Write-Log ("matched package $oem <- $orig")
    }
  }
  # Also catch by current device INF (oem65.inf etc.)
  foreach ($d in Get-DuoMi00) {
    $inf = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -ErrorAction SilentlyContinue |
      Where-Object KeyName -eq 'DEVPKEY_Device_DriverInfPath').Data
    if ($inf -match '(?i)^oem\d+\.inf$') {
      [void]$targets.Add($inf.ToLowerInvariant())
      Write-Log ("device currently uses $inf — queue delete")
    }
  }

  if ($targets.Count -eq 0) {
    Write-Log 'No Avid/community OEM packages matched (may already be gone).'
    return
  }

  foreach ($oem in $targets) {
    Write-Log "pnputil /delete-driver $oem /uninstall /force"
    Invoke-PnpUtil -Args @('/delete-driver', $oem, '/uninstall', '/force') | Out-Null
  }
}

function Install-InboxUsbAudio {
  $inf = Get-InboxWdmaUsbInf
  if (-not $inf) { throw 'wdma_usb.inf not found in DriverStore or INF\' }
  Write-Log "Installing inbox USB audio from: $inf"
  $text = Invoke-PnpUtil -Args @('/add-driver', $inf, '/install')
  return $text
}

function Clear-FxBestEffort {
  $dcRoot = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\$AudioClassGuid"
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
              Write-Log ("removed " + $_.PSPath)
            } catch {
              Write-Log ("FX strip skipped: " + $_.Exception.Message)
            }
          }
      }
  }

  $fxKeys = @(
    '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},0',
    '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},1',
    '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},2',
    '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},3',
    '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},4'
  )
  $nullGuid = '{00000000-0000-0000-0000-000000000000}'
  $sysfx = '{1da5d803-d492-4edd-8c23-e0c0ffee7f0e},5'

  foreach ($role in @('Render', 'Capture')) {
    $root = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$role"
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
      $propsPath = Join-Path $_.PSPath 'Properties'
      if (-not (Test-Path -LiteralPath $propsPath)) { return }
      $props = Get-ItemProperty -LiteralPath $propsPath -ErrorAction SilentlyContinue
      if ($null -eq $props) { return }
      $blob = @($props.PSObject.Properties | ForEach-Object { [string]$_.Value }) -join ' '
      if ($blob -notmatch $NameRegex -and $blob -notmatch $UsbVidPid) { return }
      $fxPath = Join-Path $_.PSPath 'FxProperties'
      if (-not (Test-Path -LiteralPath $fxPath)) {
        New-Item -Path $fxPath -Force -ErrorAction SilentlyContinue | Out-Null
      }
      try {
        Set-ItemProperty -LiteralPath $fxPath -Name $sysfx -Value 1 -Type DWord -Force -ErrorAction Stop
        Set-ItemProperty -LiteralPath $fxPath -Name $fxKeys[4] -Value '' -Force -ErrorAction SilentlyContinue
        for ($i = 0; $i -le 3; $i++) {
          Set-ItemProperty -LiteralPath $fxPath -Name $fxKeys[$i] -Value $nullGuid -Force -ErrorAction SilentlyContinue
        }
        Write-Log ("SysFx disabled $role " + $_.PSChildName)
      } catch {
        Write-Log ("MMDevices FxProperties locked (skip): " + $_.Exception.Message)
      }
    }
  }
}

# ---- main ----
Request-Elevation
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Write-Log 'Fast Track Duo -> Microsoft USB Audio class install starting'
Write-Log ("whoami=" + [Security.Principal.WindowsIdentity]::GetCurrent().Name)
Write-Log ("TryOemInf=" + $TryOemInf.IsPresent)

# 1) Disable MI_00 so package delete is less sticky
foreach ($d in Get-DuoMi00) {
  try {
    Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop
    Write-Log ("disabled " + $d.InstanceId)
  } catch {
    Write-Log ("disable: " + $_.Exception.Message)
    Invoke-PnpUtil -Args @('/disable-device', $d.InstanceId) | Out-Null
  }
}

# 2) Delete Avid packages (critical — must beat VID/PID rank)
Remove-AvidPackages

# Wipe leftover DriverStore folders if pnputil left orphans
Get-ChildItem (Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository') -Directory -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '(?i)^avidfasttrackduo\.inf_' } |
  ForEach-Object {
    try {
      $prev = $ErrorActionPreference
      $ErrorActionPreference = 'Continue'
      & takeown.exe /f $_.FullName /r /d Y 2>&1 | Out-Null
      & icacls.exe $_.FullName /grant '*S-1-5-32-544:F' /T 2>&1 | Out-Null
      $ErrorActionPreference = $prev
      Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
      Write-Log ("removed DriverStore " + $_.Name)
    } catch {
      Write-Log ("DriverStore wipe: " + $_.Exception.Message)
    }
  }

# 3) Optional unsigned OEM INF (usually rejected)
if ($TryOemInf -and (Test-Path -LiteralPath $OemInfPath)) {
  Write-Log 'Trying community OEM INF (may fail without catalog)...'
  $oemOut = Invoke-PnpUtil -Args @('/add-driver', $OemInfPath, '/install')
  if ($oemOut -match '(?i)Failed to add|does not contain digital signature') {
    Write-Log 'OEM INF rejected (expected without signature). Continuing with inbox.'
  }
}

# 4) Install Microsoft wdma_usb.inf from DriverStore
$null = Install-InboxUsbAudio

# 5) Re-enumerate device: remove node then scan so Class_01 can bind
foreach ($d in Get-DuoMi00) {
  Write-Log ("remove-device " + $d.InstanceId)
  Invoke-PnpUtil -Args @('/remove-device', $d.InstanceId) | Out-Null
}
Start-Sleep -Seconds 2
Invoke-PnpUtil -Args @('/scan-devices') | Out-Null
Start-Sleep -Seconds 3

# Enable / restart if present
foreach ($d in Get-DuoMi00) {
  try {
    Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
  } catch {}
  Invoke-PnpUtil -Args @('/enable-device', $d.InstanceId) | Out-Null
  Invoke-PnpUtil -Args @('/restart-device', $d.InstanceId) | Out-Null
}

Clear-FxBestEffort

try {
  Restart-Service -Name Audiosrv, AudioEndpointBuilder -Force -ErrorAction Stop
  Write-Log 'audio services restarted'
} catch {
  Write-Log ("audio restart: " + $_.Exception.Message)
}

# 6) Verify
$ok = $false
$pendingReboot = $false
$devs = @(Get-DuoMi00)
if ($devs.Count -eq 0) {
  Write-Log 'WARNING: MI_00 not present after scan — unplug/replug USB then Verify.'
} else {
  foreach ($d in $devs) {
    $svc = Get-DuoService $d.InstanceId
    $inf = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -ErrorAction SilentlyContinue |
      Where-Object KeyName -eq 'DEVPKEY_Device_DriverInfPath').Data
    $prov = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -ErrorAction SilentlyContinue |
      Where-Object KeyName -eq 'DEVPKEY_Device_DriverProvider').Data
    Write-Log ("result status=$($d.Status) svc=$svc inf=$inf prov=$prov id=$($d.InstanceId)")
    if ($svc -eq 'usbaudio') { $ok = $true }
    if ("$svc$inf" -match '(?i)pending|reboot') { $pendingReboot = $true }
  }
}

# Detect reboot-needed from recent log lines / known message
if (-not $ok) {
  $tail = Get-Content -LiteralPath $LogFile -Raw -ErrorAction SilentlyContinue
  if ($tail -match '(?i)pending system reboot|reboot required') {
    $pendingReboot = $true
  }
}

Write-Host ''
if ($ok) {
  Write-Host 'SUCCESS: Duo is bound to Microsoft usbaudio.'
  Write-Host 'Set Spatial sound Off and disable Enhancements, then test playback.'
} else {
  Write-Host 'NOT YET on usbaudio.'
  if ($pendingReboot -or $AllowRebootPrompt) {
    Write-Host 'A reboot is likely required to finish deleting the Avid package.'
    Write-Host 'Reboot, then run again:'
    Write-Host '  sudo .\native-driver\usbaudio\Install-UsbAudio.cmd'
  } else {
    Write-Host '1) Reboot Windows (driver delete may be pending).'
    Write-Host '2) sudo .\native-driver\usbaudio\Install-UsbAudio.cmd'
    Write-Host '3) .\native-driver\usbaudio\Verify-UsbAudio.ps1'
  }
  # Still list remaining Avid oem packages for diagnosis
  Write-Log 'Post-check: Avid packages still published?'
  Invoke-PnpUtil -Args @('/enum-drivers') | Out-Null
}

Write-Host ("Log: $LogFile")
if (-not $ok) { exit 1 }
exit 0
