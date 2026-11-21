#Requires -Version 5.1
<#
.SYNOPSIS
  Build FtdSoftVol.sys with VS + WDK (WindowsKernelModeDriver10.0).
#>
[CmdletBinding()]
param(
  [ValidateSet('Debug', 'Release')]
  [string]$Configuration = 'Release',
  [ValidateSet('x64')]
  [string]$Platform = 'x64'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Sln = Join-Path $Root 'FtdSoftVol.sln'

function Find-MSBuild {
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (Test-Path $vswhere) {
    $found = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' |
      Select-Object -First 1
    if ($found) { return $found }
  }
  $candidates = @(
    "${env:ProgramFiles}\Microsoft Visual Studio\18\Community\MSBuild\Current\Bin\MSBuild.exe",
    "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe",
    "${env:ProgramFiles}\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe",
    "${env:ProgramFiles}\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe"
  )
  foreach ($c in $candidates) {
    if (Test-Path $c) { return $c }
  }
  return $null
}

$msbuild = Find-MSBuild
if (-not $msbuild) {
  throw 'MSBuild not found. Install Visual Studio with C++ workload.'
}

Write-Host "MSBuild: $msbuild"
Write-Host "Building $Sln ($Configuration|$Platform)"

& $msbuild $Sln /p:Configuration=$Configuration /p:Platform=$Platform /v:m
if ($LASTEXITCODE -ne 0) {
  throw @"
MSBuild failed ($LASTEXITCODE).
Install Windows Driver Kit + VS integration so platform toolset
WindowsKernelModeDriver10.0 is available (VS Installer → Individual components).
"@
}

$sys = Join-Path $Root "$Configuration\$Platform\FtdSoftVol.sys"
if (-not (Test-Path $sys)) {
  $alt = Join-Path $Root "x64\$Configuration\FtdSoftVol.sys"
  if (Test-Path $alt) { $sys = $alt }
}

if (Test-Path $sys) {
  $pkg = Join-Path $Root 'package'
  New-Item -ItemType Directory -Force -Path $pkg | Out-Null
  Copy-Item $sys (Join-Path $pkg 'FtdSoftVol.sys') -Force
  Copy-Item (Join-Path $Root 'inf\FtdSoftVol.inf') (Join-Path $pkg 'FtdSoftVol.inf') -Force
  Write-Host "OK: $sys"
  Write-Host "Staged: $pkg"
} else {
  Write-Host 'Build reported success but FtdSoftVol.sys was not found in the usual output folders.'
}
