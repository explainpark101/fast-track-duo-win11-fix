param(
  [Parameter(Mandatory=$true)][string]$InfPath,
  [Parameter(Mandatory=$true)][string]$InboxInf,
  [Parameter(Mandatory=$true)][string]$LogFile,
  [Parameter(Mandatory=$true)][string]$UsbVidPid,
  [Parameter(Mandatory=$true)][string]$AudioHwId,
  [Parameter(Mandatory=$true)][string]$AudioClassGuid,
  [Parameter(Mandatory=$true)][string]$NameRegex,
  [Parameter(Mandatory=$true)][string]$SkipOemInf
)

$ErrorActionPreference = "Continue"
function L([string]$m) {
  Add-Content -LiteralPath $LogFile -Value ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m) -Encoding UTF8
}

L ("whoami=" + [Security.Principal.WindowsIdentity]::GetCurrent().Name)
L ("INF=" + $InfPath)
L ("InboxInf=" + $InboxInf)

# --- Remove Duo audio function devices (keep composite parent if possible) ---
Get-PnpDevice -ErrorAction SilentlyContinue |
  Where-Object {
    $_.InstanceId -like ("USB\{0}&MI_00*" -f $UsbVidPid) -or
    ($_.Class -eq 'MEDIA' -and $_.InstanceId -like ("USB\{0}*" -f $UsbVidPid))
  } |
  ForEach-Object {
    try {
      Disable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
      L ("disabled " + $_.InstanceId)
    } catch { L ("disable: " + $_.Exception.Message) }
  }

# --- Delete Avid / community Duo driver packages ---
try {
  $drivers = & pnputil.exe /enum-drivers
  $block = $drivers -join "`n"
  $patterns = @(
    '(?ms)Published Name:\s+(oem\d+\.inf).*?Original Name:\s+(AvidFastTrackDuo\.inf)',
    '(?ms)Published Name:\s+(oem\d+\.inf).*?Original Name:\s+(FastTrackDuoUsbAudio\.inf)',
    '(?ms)Published Name:\s+(oem\d+\.inf).*?Original Name:\s+(FastTrackDuoNew\.inf)'
  )
  foreach ($pat in $patterns) {
    foreach ($m in [regex]::Matches($block, $pat)) {
      $oem = $m.Groups[1].Value
      L ("deleting package " + $oem + " (" + $m.Groups[2].Value + ")")
      & pnputil.exe /delete-driver $oem /uninstall /force 2>&1 | ForEach-Object { L (($_ | Out-String).Trim()) }
    }
  }
} catch { L ("pnputil enum/delete: " + $_.Exception.Message) }

Get-ChildItem "C:\Windows\System32\DriverStore\FileRepository" -Directory -ErrorAction SilentlyContinue |
  Where-Object {
    $_.Name -like "avidfasttrackduo.inf_*" -or
    $_.Name -like "fasttrackduousbaudio.inf_*" -or
    $_.Name -like "fasttrackduonew.inf_*"
  } |
  ForEach-Object {
    try {
      takeown /f $_.FullName /r /d Y | Out-Null
      icacls $_.FullName /grant "*S-1-5-32-544:F" /T | Out-Null
      Remove-Item -LiteralPath $_.FullName -Recurse -Force
      L ("removed DriverStore " + $_.Name)
    } catch { L ("DriverStore wipe: " + $_.Exception.Message) }
  }

$installed = $false

if ($SkipOemInf -ne "1") {
  L "pnputil /add-driver OEM USB Audio INF..."
  $add = & pnputil.exe /add-driver $InfPath /install 2>&1
  $add | ForEach-Object { L (($_ | Out-String).Trim()) }
  $text = ($add | Out-String)
  if ($text -match 'Published Name|added successfully|already installed|/install') {
    $installed = $true
  }
}

# Fallback: force inbox wdma_usb.inf onto the hardware ID
if (-not $installed) {
  L "OEM INF path skipped or failed; forcing inbox wdma_usb.inf"
  $dev = Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -like ("USB\{0}&MI_00*" -f $UsbVidPid) } |
    Select-Object -First 1
  if ($null -eq $dev) {
    & pnputil.exe /scan-devices 2>&1 | ForEach-Object { L (($_ | Out-String).Trim()) }
    Start-Sleep -Seconds 3
    $dev = Get-PnpDevice -ErrorAction SilentlyContinue |
      Where-Object { $_.InstanceId -like ("USB\{0}&MI_00*" -f $UsbVidPid) } |
      Select-Object -First 1
  }
  if ($null -ne $dev) {
    L ("update-driver " + $dev.InstanceId)
    $upd = & pnputil.exe /update-driver $dev.InstanceId $InboxInf /force 2>&1
    $upd | ForEach-Object { L (($_ | Out-String).Trim()) }
    $installed = $true
  } else {
    L "WARNING: MI_00 device not found after package removal; scan and replug USB"
    & pnputil.exe /scan-devices 2>&1 | ForEach-Object { L (($_ | Out-String).Trim()) }
  }
}

# Ensure device is started
Get-PnpDevice -ErrorAction SilentlyContinue |
  Where-Object { $_.InstanceId -like ("USB\{0}&MI_00*" -f $UsbVidPid) } |
  ForEach-Object {
    try {
      Enable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
      & pnputil.exe /restart-device $_.InstanceId 2>&1 | ForEach-Object { L (($_ | Out-String).Trim()) }
      L ("service=" + (Get-PnpDeviceProperty -InstanceId $_.InstanceId |
        Where-Object KeyName -eq 'DEVPKEY_Device_Service').Data)
      L ("inf=" + (Get-PnpDeviceProperty -InstanceId $_.InstanceId |
        Where-Object KeyName -eq 'DEVPKEY_Device_DriverInfPath').Data)
      L ("desc=" + $_.FriendlyName)
    } catch { L ("enable/restart: " + $_.Exception.Message) }
  }

# --- Strip FX leftovers (DeviceClasses) ---
$dcRoot = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\$AudioClassGuid"
if (Test-Path $dcRoot) {
  Get-ChildItem $dcRoot -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -like "*$UsbVidPid*" } |
    ForEach-Object {
      Get-ChildItem -LiteralPath $_.PSPath -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.PSPath -match '\\FX\\0$' -or $_.PSChildName -eq 'MSFX' -or $_.PSChildName -eq 'MSFX' } |
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

foreach ($role in @("Render", "Capture")) {
  $root = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$role"
  if (-not (Test-Path $root)) { continue }
  Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
    $propsPath = Join-Path $_.PSPath "Properties"
    if (-not (Test-Path -LiteralPath $propsPath)) { return }
    $props = Get-ItemProperty -LiteralPath $propsPath -ErrorAction SilentlyContinue
    $blob = @($props.PSObject.Properties | ForEach-Object { [string]$_.Value }) -join " "
    if ($blob -notmatch $NameRegex -and $blob -notmatch $UsbVidPid) { return }
    $fxPath = Join-Path $_.PSPath "FxProperties"
    if (-not (Test-Path -LiteralPath $fxPath)) { New-Item -Path $fxPath -Force | Out-Null }
    try {
      Set-ItemProperty -LiteralPath $fxPath -Name $sysfx -Value 1 -Type DWord -Force
      Set-ItemProperty -LiteralPath $fxPath -Name $fxKeys[4] -Value "" -Force -ErrorAction SilentlyContinue
      for ($i = 0; $i -le 3; $i++) {
        Set-ItemProperty -LiteralPath $fxPath -Name $fxKeys[$i] -Value $nullGuid -Force -ErrorAction SilentlyContinue
      }
      L ("SysFx disabled $role " + $_.PSChildName)
    } catch { L ("MMDevices: " + $_.Exception.Message) }
  }
}

try {
  Restart-Service -Name Audiosrv, AudioEndpointBuilder -Force -ErrorAction Stop
  L "audio services restarted"
} catch { L ("audio restart: " + $_.Exception.Message) }

try { & pnputil.exe /scan-devices 2>&1 | ForEach-Object { L (($_ | Out-String).Trim()) } } catch {}

L "WORKER_DONE"
