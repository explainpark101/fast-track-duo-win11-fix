#Requires -Version 5.1
<#
.SYNOPSIS
  Check whether Duo MI_00 is bound to Microsoft usbaudio (not Avid).
#>
[CmdletBinding()]
param()

$devs = Get-PnpDevice -ErrorAction SilentlyContinue |
  Where-Object { $_.InstanceId -like 'USB\VID_0B0F&PID_2036&MI_00*' }

if (-not $devs) {
  Write-Host 'FAIL: no USB\VID_0B0F&PID_2036&MI_00 device present'
  exit 2
}

$ok = $true
foreach ($d in $devs) {
  $svc = (Get-PnpDeviceProperty -InstanceId $d.InstanceId |
    Where-Object KeyName -eq 'DEVPKEY_Device_Service').Data
  $inf = (Get-PnpDeviceProperty -InstanceId $d.InstanceId |
    Where-Object KeyName -eq 'DEVPKEY_Device_DriverInfPath').Data
  $prov = (Get-PnpDeviceProperty -InstanceId $d.InstanceId |
    Where-Object KeyName -eq 'DEVPKEY_Device_DriverProvider').Data
  Write-Host ("Device:  " + $d.FriendlyName)
  Write-Host ("  Id:    " + $d.InstanceId)
  Write-Host ("  Status:" + $d.Status)
  Write-Host ("  Svc:   " + $svc)
  Write-Host ("  Inf:   " + $inf)
  Write-Host ("  Prov:  " + $prov)
  if ($svc -ne 'usbaudio') {
    Write-Host '  --> EXPECTED service usbaudio'
    $ok = $false
  }
}

if ($ok) {
  Write-Host 'PASS: bound to usbaudio'
  exit 0
}
Write-Host 'FAIL: still on proprietary / other driver — run Install-UsbAudio.cmd elevated'
exit 1
