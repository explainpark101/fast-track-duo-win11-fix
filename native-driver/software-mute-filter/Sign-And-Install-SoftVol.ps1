#Requires -Version 5.1
<#
.SYNOPSIS
  Test-sign FtdSoftVol.sys and attach it as UpperFilter on Duo (usbaudio).

.DESCRIPTION
  Uses a manual attach path (copy .sys + create service + UpperFilters) because
  Inf2Cat from WDK 26100 hits BadImageFormat (0x8007000B) on this host.
  Requires elevation (UAC). testsigning should be on.
#>
[CmdletBinding()]
param(
  [switch]$SkipTestSigningEnable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Package = Join-Path $Root 'package'
$Sys = Join-Path $Package 'FtdSoftVol.sys'
$DestSys = Join-Path $env:SystemRoot 'System32\drivers\FtdSoftVol.sys'
$ServiceName = 'FtdSoftVol'
$UsbVidPid = 'VID_0B0F&PID_2036'

function Write-Step($m) { Write-Host ""; Write-Host "=== $m ===" -ForegroundColor Cyan }

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
  throw 'Must run elevated. Use Sign-And-Install-SoftVol.cmd (UAC).'
}

if (-not (Test-Path $Sys)) {
  throw "Missing $Sys — run Build-SoftVol.ps1 first."
}

Write-Step 'Test signing mode'
$bcd = (bcdedit /enum '{current}' 2>&1 | Out-String)
if ($bcd -notmatch 'testsigning\s+Yes') {
  if ($SkipTestSigningEnable) {
    Write-Host 'WARNING: testsigning is OFF'
  } else {
    bcdedit /set testsigning on | Out-Host
    Write-Host 'Enabled testsigning (reboot needed before first kernel load if this was first enable).'
  }
} else {
  Write-Host 'testsigning already Yes'
}

Write-Step 'Code-signing certificate'
$store = 'Cert:\CurrentUser\My'
$cert = Get-ChildItem $store -CodeSigningCert -ErrorAction SilentlyContinue |
  Where-Object { $_.Subject -eq 'CN=FtdSoftVol Test' } |
  Select-Object -First 1
if (-not $cert) {
  $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=FtdSoftVol Test' `
    -CertStoreLocation $store -NotAfter (Get-Date).AddYears(5)
}
$cer = Join-Path $Package 'FtdSoftVolTest.cer'
Export-Certificate -Cert $cert -FilePath $cer -Force | Out-Null
Import-Certificate -FilePath $cer -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
Import-Certificate -FilePath $cer -CertStoreLocation 'Cert:\LocalMachine\TrustedPublisher' | Out-Null
Write-Host "Cert thumbprint=$($cert.Thumbprint)"

Write-Step 'Sign + install FtdSoftVol.sys'
$sig = Set-AuthenticodeSignature -FilePath $Sys -Certificate $cert -HashAlgorithm SHA256
Write-Host ("Signature Status={0}" -f $sig.Status)

# Unload audio stack so System32\drivers\FtdSoftVol.sys is not locked
foreach ($svc in @('Audiosrv', 'AudioEndpointBuilder')) {
  & net.exe stop $svc /y 2>&1 | Out-Null
}
$duoDevs = Get-PnpDevice -ErrorAction SilentlyContinue |
  Where-Object { $_.InstanceId -like ("USB\{0}&MI_00*" -f $UsbVidPid) }
foreach ($d in $duoDevs) {
  try {
    Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop
    Write-Host ("disabled " + $d.InstanceId)
  } catch {
    Write-Host ("disable: " + $_.Exception.Message)
  }
}
Start-Sleep -Seconds 2
& sc.exe stop $ServiceName 2>&1 | Out-Null
Start-Sleep -Seconds 1

$copied = $false
try {
  Copy-Item -LiteralPath $Sys -Destination $DestSys -Force -ErrorAction Stop
  $copied = $true
  Write-Host "Copied to $DestSys"
} catch {
  Write-Host ("live copy failed: " + $_.Exception.Message)
  # Schedule replace on next reboot (MOVEFILE_DELAY_UNTIL_REBOOT | REPLACE_EXISTING)
  Add-Type -Namespace Ftd -Name Native -MemberDefinition @"
    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, SetLastError=true)]
    public static extern bool MoveFileEx(string existing, string newFile, int flags);
"@ -ErrorAction SilentlyContinue
  $pending = Join-Path $env:TEMP 'FtdSoftVol.pending.sys'
  Copy-Item -LiteralPath $Sys -Destination $pending -Force
  $flags = 0x5  # MOVEFILE_REPLACE_EXISTING | MOVEFILE_DELAY_UNTIL_REBOOT
  if ([Ftd.Native]::MoveFileEx($pending, $DestSys, $flags)) {
    Write-Host "Scheduled replace of $DestSys on next reboot"
    $script:NeedsRebootForSys = $true
  } else {
    throw "Cannot replace locked FtdSoftVol.sys (win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
  }
}

foreach ($svc in @('AudioEndpointBuilder', 'Audiosrv')) {
  & net.exe start $svc 2>&1 | Out-Null
}

Write-Step 'Kernel service'
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $svc) {
  & sc.exe create $ServiceName type= kernel start= demand binPath= "\SystemRoot\System32\drivers\FtdSoftVol.sys" DisplayName= "Fast Track Duo Software Mute Filter" | Out-Host
} else {
  Write-Host "Service $ServiceName already exists"
}
& sc.exe description $ServiceName "Upper filter hiding USB VOLUME/MUTE for software volume path" | Out-Host

Write-Step 'Attach UpperFilters on Duo MI_00'
$devs = Get-PnpDevice -ErrorAction SilentlyContinue |
  Where-Object { $_.InstanceId -like ("USB\{0}&MI_00*" -f $UsbVidPid) }
if (-not $devs) {
  throw 'Duo MI_00 not present. Plug in the device.'
}

foreach ($d in $devs) {
  $key = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.InstanceId)"
  if (-not (Test-Path -LiteralPath $key)) {
    throw "Enum key missing: $key"
  }
  $filters = @()
  $existing = Get-ItemProperty -LiteralPath $key -Name UpperFilters -ErrorAction SilentlyContinue
  if ($null -ne $existing -and $null -ne $existing.UpperFilters) {
    $filters = @($existing.UpperFilters)
  }
  if ($filters -notcontains $ServiceName) {
    $filters = @($ServiceName) + $filters
    New-ItemProperty -LiteralPath $key -Name UpperFilters -PropertyType MultiString -Value $filters -Force | Out-Null
    Write-Host ("Set UpperFilters={0} on {1}" -f ($filters -join ','), $d.InstanceId)
  } else {
    Write-Host ("UpperFilters already has {0} on {1}" -f $ServiceName, $d.InstanceId)
  }

  $svcName = (Get-PnpDeviceProperty -InstanceId $d.InstanceId |
    Where-Object KeyName -eq 'DEVPKEY_Device_Service').Data
  Write-Host ("Function service={0}" -f $svcName)
  if ($svcName -ne 'usbaudio') {
    Write-Host 'WARNING: function driver is not usbaudio. Prefer Install-UsbAudio first.'
  }

  Write-Host "Restarting device $($d.InstanceId)..."
  Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
}

Write-Step 'Verify'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'Verify-SoftVol.ps1')
$verify = $LASTEXITCODE

if ($bcd -notmatch 'testsigning\s+Yes') {
  Write-Host ''
  Write-Host 'IMPORTANT: testsigning was just enabled — reboot, then re-run this script or Verify-SoftVol.ps1.'
}

exit $verify
