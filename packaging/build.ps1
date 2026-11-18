#Requires -Version 5.1
<#
.SYNOPSIS
  Build release executables with .NET Framework csc (reliable on mixed SDK hosts):
    - dist/Fast-Track-Duo-USBAudio.exe          (recommended: bind Microsoft usbaudio.sys)
    - dist/1.0.4-patch.exe
    - dist/Fast-Track-Duo-Driver_fix.1.0.0.exe

  CI (windows-latest) can also use this path; no SDK apphost required.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..')).Path
$Dist = Join-Path $Root 'dist'
$Staging = Join-Path $Root 'packaging\staging'
$PatchDir = Join-Path $Root 'patch'
$DriverDir = Join-Path $Root 'driver\1.0.5'
$UsbAudioDir = Join-Path $Root 'native-driver\usbaudio'
$ProgramCs = Join-Path $Root 'packaging\ExeHost\Program.cs'
$Manifest = Join-Path $Root 'packaging\ExeHost\app.manifest'

function Write-Step([string]$m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

function Get-Csc {
  $candidates = @(
    "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\Roslyn\csc.exe",
    "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\Roslyn\csc.exe",
    "${env:ProgramFiles}\Microsoft Visual Studio\18\Community\MSBuild\Current\Bin\Roslyn\csc.exe",
    "${env:windir}\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
  )
  foreach ($c in $candidates) {
    if (Test-Path $c) { return $c }
  }
  $found = Get-ChildItem "${env:ProgramFiles}\Microsoft Visual Studio","${env:ProgramFiles(x86)}\Microsoft Visual Studio" -Recurse -Filter csc.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\Roslyn\\csc\.exe$' } |
    Select-Object -First 1 -ExpandProperty FullName
  if ($found) { return $found }
  throw "csc.exe not found. Install .NET Framework 4.x targeting pack / VS Build Tools."
}

function Ensure-DriverBinaries {
  $sys = Join-Path $DriverDir 'AvidFastTrackDuo.sys'
  $cat = Join-Path $DriverDir 'AvidFastTrackDuo.cat'
  if ((Test-Path $sys) -and (Test-Path $cat)) { return }

  $sysSrc = @(
    (Join-Path $Root 'msi64\StreamingSYS'),
    (Join-Path $Root 'driver_bin\maudio_streaming.sys'),
    (Join-Path $Root 'patch\AvidFastTrackDuo.sys')
  ) | Where-Object { Test-Path $_ } | Select-Object -First 1

  $catSrc = @(
    (Join-Path $Root 'msi64\StreamingCAT'),
    (Join-Path $Root 'driver_bin\maudio_streaming.cat')
  ) | Where-Object { Test-Path $_ } | Select-Object -First 1

  if (-not $sysSrc -or -not $catSrc) {
    throw "Missing AvidFastTrackDuo.sys / .cat under driver\1.0.5."
  }

  New-Item -ItemType Directory -Force -Path $DriverDir | Out-Null
  Copy-Item $sysSrc $sys -Force
  Copy-Item $catSrc $cat -Force
}

function New-ZipFromFolder([string]$SourceDir, [string]$ZipPath) {
  if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [IO.Compression.ZipFile]::CreateFromDirectory($SourceDir, $ZipPath, [IO.Compression.CompressionLevel]::Optimal, $false)
}

function Publish-Package {
  param(
    [Parameter(Mandatory)][string]$AssemblyName,
    [Parameter(Mandatory)][string]$Title,
    [Parameter(Mandatory)][string]$PayloadZip,
    [Parameter(Mandatory)][string]$OutExe
  )

  $csc = Get-Csc
  $work = Join-Path $Staging ("compile-" + $AssemblyName)
  if (Test-Path $work) { Remove-Item $work -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $work | Out-Null

  $outPath = Join-Path $work ($AssemblyName + '.exe')

  Write-Step "csc $AssemblyName"
  $args = @(
    '/nologo',
    '/target:exe',
    '/platform:anycpu',
    "/out:$outPath",
    "/win32manifest:$Manifest",
    "/resource:$PayloadZip,payload.zip",
    '/r:System.dll',
    '/r:System.Core.dll',
    '/r:System.IO.Compression.dll',
    '/r:System.IO.Compression.FileSystem.dll'
  )

  # Assembly title attribute via temporary wrapper
  $attrCs = Join-Path $work 'AssemblyInfo.cs'
  @"
using System.Reflection;
[assembly: AssemblyTitle("$Title")]
[assembly: AssemblyProduct("$Title")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]
"@ | Set-Content -LiteralPath $attrCs -Encoding ASCII

  & $csc @args $ProgramCs $attrCs
  if ($LASTEXITCODE -ne 0) { throw "csc failed for $AssemblyName" }
  if (-not (Test-Path $outPath)) { throw "Missing $outPath" }

  Copy-Item $outPath $OutExe -Force
  Write-Host "Wrote $OutExe ($((Get-Item $OutExe).Length) bytes)"
}

Write-Step 'Prepare'
New-Item -ItemType Directory -Force -Path $Dist, $Staging | Out-Null
Ensure-DriverBinaries

if (-not (Test-Path (Join-Path $UsbAudioDir 'Install-UsbAudio.ps1'))) { throw 'Missing native-driver\usbaudio\Install-UsbAudio.ps1' }
if (-not (Test-Path (Join-Path $PatchDir 'Install-Patch.ps1'))) { throw 'Missing patch\Install-Patch.ps1' }
if (-not (Test-Path (Join-Path $DriverDir 'Install-Driver.ps1'))) { throw 'Missing driver\1.0.5\Install-Driver.ps1' }
if (-not (Test-Path (Join-Path $DriverDir 'AvidFastTrackDuo.inf'))) { throw 'Missing driver\1.0.5\AvidFastTrackDuo.inf' }
if (-not (Test-Path $ProgramCs)) { throw 'Missing packaging\ExeHost\Program.cs' }

Write-Step 'Stage Fast-Track-Duo-USBAudio payload'
$usbStage = Join-Path $Staging 'payload-usbaudio'
if (Test-Path $usbStage) { Remove-Item $usbStage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $usbStage | Out-Null
Copy-Item (Join-Path $UsbAudioDir 'Install-UsbAudio.ps1') $usbStage -Force
Copy-Item (Join-Path $UsbAudioDir 'Verify-UsbAudio.ps1') $usbStage -Force
Copy-Item (Join-Path $UsbAudioDir 'Install-UsbAudio.cmd') $usbStage -Force -ErrorAction SilentlyContinue
Copy-Item (Join-Path $UsbAudioDir 'FastTrackDuoUsbAudio.inf') $usbStage -Force -ErrorAction SilentlyContinue
$usbZip = Join-Path $Staging 'payload-usbaudio.zip'
New-ZipFromFolder $usbStage $usbZip

Write-Step 'Stage 1.0.4-patch payload'
$patchStage = Join-Path $Staging 'payload-1.0.4-patch'
if (Test-Path $patchStage) { Remove-Item $patchStage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $patchStage | Out-Null
Copy-Item (Join-Path $PatchDir 'Install-Patch.ps1') $patchStage -Force
Copy-Item (Join-Path $PatchDir 'AvidFastTrackDuo.nofx.inf') $patchStage -Force
$patchZip = Join-Path $Staging 'payload-1.0.4-patch.zip'
New-ZipFromFolder $patchStage $patchZip

Write-Step 'Stage Fast-Track-Duo-Driver_fix.1.0.0 payload'
$drvStage = Join-Path $Staging 'payload-driver-fix'
if (Test-Path $drvStage) { Remove-Item $drvStage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $drvStage | Out-Null
Copy-Item (Join-Path $DriverDir 'Install-Driver.ps1') $drvStage -Force
Copy-Item (Join-Path $DriverDir 'AvidFastTrackDuo.inf') $drvStage -Force
Copy-Item (Join-Path $DriverDir 'AvidFastTrackDuo.sys') $drvStage -Force
Copy-Item (Join-Path $DriverDir 'AvidFastTrackDuo.cat') $drvStage -Force -ErrorAction SilentlyContinue
$drvZip = Join-Path $Staging 'payload-driver-fix.zip'
New-ZipFromFolder $drvStage $drvZip

Publish-Package `
  -AssemblyName 'Fast-Track-Duo-USBAudio' `
  -Title 'Fast Track Duo USB Audio Class' `
  -PayloadZip $usbZip `
  -OutExe (Join-Path $Dist 'Fast-Track-Duo-USBAudio.exe')

Publish-Package `
  -AssemblyName '1.0.4-patch' `
  -Title 'Fast Track Duo 1.0.4 Patch' `
  -PayloadZip $patchZip `
  -OutExe (Join-Path $Dist '1.0.4-patch.exe')

Publish-Package `
  -AssemblyName 'Fast-Track-Duo-Driver_fix.1.0.0' `
  -Title 'Fast Track Duo Driver Fix 1.0.0' `
  -PayloadZip $drvZip `
  -OutExe (Join-Path $Dist 'Fast-Track-Duo-Driver_fix.1.0.0.exe')

Write-Step 'Done'
Get-ChildItem $Dist -Filter *.exe | Format-Table Name, Length, LastWriteTime
