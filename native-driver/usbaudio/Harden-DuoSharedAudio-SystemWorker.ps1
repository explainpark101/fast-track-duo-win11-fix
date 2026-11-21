#Requires -Version 5.1
# Runs as SYSTEM (invoked by Harden-DuoSharedAudio.ps1 scheduled task).
$ErrorActionPreference = 'Continue'
$UsbVidPid = 'VID_0B0F&PID_2036'
$NameRegex = 'Fast Track Duo|Avid Fast Track Duo|USB Audio Class'
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
$n = 0

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
    $name = $props.'{a45c254e-df1c-4efd-8020-67d146a850e0},2'
    Write-Output ("Duo {0} {1} ({2})" -f $role, $_.PSChildName, $name)
    New-ItemProperty -LiteralPath $propsPath -Name $ExclusiveAllow -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -LiteralPath $propsPath -Name $ExclusivePriority -PropertyType DWord -Value 0 -Force | Out-Null
    Write-Output '  exclusive mode OFF, exclusive priority OFF'
    $fxPath = Join-Path $_.PSPath 'FxProperties'
    if (-not (Test-Path -LiteralPath $fxPath)) {
      New-Item -Path $fxPath -Force | Out-Null
    }
    New-ItemProperty -LiteralPath $fxPath -Name $SysFxDisable -PropertyType DWord -Value 1 -Force | Out-Null
    Set-ItemProperty -LiteralPath $fxPath -Name $FxKeys[4] -Value '' -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -le 3; $i++) {
      Set-ItemProperty -LiteralPath $fxPath -Name $FxKeys[$i] -Value $NullGuid -Force -ErrorAction SilentlyContinue
    }
    Write-Output '  SysFx disabled / FX CLSIDs cleared'
    $n++
  }
}
Write-Output ("touched=$n")
exit 0
