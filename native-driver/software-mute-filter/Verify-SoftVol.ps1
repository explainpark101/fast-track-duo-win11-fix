#Requires -Version 5.1
<#
.SYNOPSIS
  Verify Duo MI_00 uses usbaudio + FtdSoftVol UpperFilters.
#>
[CmdletBinding()]
param()

$UsbVidPid = 'VID_0B0F&PID_2036'
$ok = $true

$devs = Get-PnpDevice -ErrorAction SilentlyContinue |
  Where-Object { $_.InstanceId -like ("USB\{0}&MI_00*" -f $UsbVidPid) }

if (-not $devs) {
  Write-Host 'FAIL: no USB\VID_0B0F&PID_2036&MI_00 device present'
  exit 2
}

foreach ($d in $devs) {
  $svc = (Get-PnpDeviceProperty -InstanceId $d.InstanceId |
    Where-Object KeyName -eq 'DEVPKEY_Device_Service').Data
  $prov = (Get-PnpDeviceProperty -InstanceId $d.InstanceId |
    Where-Object KeyName -eq 'DEVPKEY_Device_DriverProvider').Data

  $filters = @()
  $key = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.InstanceId)"
  $prop = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
  if ($prop -and $prop.UpperFilters) {
    $filters = @($prop.UpperFilters)
  }

  Write-Host ("Instance : {0}" -f $d.InstanceId)
  Write-Host ("Status   : {0}" -f $d.Status)
  Write-Host ("Service  : {0}" -f $svc)
  Write-Host ("Provider : {0}" -f $prov)
  Write-Host ("UpperFilters: {0}" -f ($(if ($filters.Count) { $filters -join ', ' } else { '(none)' })))

  if ($svc -ne 'usbaudio') {
    Write-Host 'FAIL: Service must be usbaudio (Avid .sys must not be loaded)'
    $ok = $false
  }
  if ($filters -notcontains 'FtdSoftVol') {
    Write-Host 'FAIL: UpperFilters must include FtdSoftVol'
    $ok = $false
  }

  $svcKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\FtdSoftVol'
  if (-not (Test-Path -LiteralPath $svcKey)) {
    Write-Host 'FAIL: service FtdSoftVol is not registered'
    $ok = $false
  } else {
    $img = (Get-ItemProperty -LiteralPath $svcKey).ImagePath
    Write-Host ("ImagePath: {0}" -f $img)
  }
}

# Soft check: driver object loaded
$mod = Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -eq 'FtdSoftVol' }
if ($mod) {
  Write-Host ("FtdSoftVol state: {0}" -f $mod.State)
} else {
  Write-Host 'NOTE: Win32_SystemDriver did not list FtdSoftVol (may still be demand-start until stack builds)'
}

if ($ok) {
  Write-Host 'PASS: usbaudio + FtdSoftVol filter registered'
  exit 0
}

Write-Host 'FAIL: see messages above'
exit 1
