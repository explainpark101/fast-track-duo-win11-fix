#Requires -Version 5.1
<#
.SYNOPSIS
  Install Visual Studio C++ + matching WDK so FtdSoftVol.sys can build locally.

.DESCRIPTION
  1) Ensures VS Community has Desktop C++ / MSVC / Spectre-mitigated libs
  2) Installs Windows Driver Kit matching the installed Windows 10 kit (prefer 26100)
  3) Adds the VS "Windows Driver Kit" component so toolset
     WindowsKernelModeDriver10.0 is available to MSBuild

  Run elevated (UAC). Re-run safely if partially installed.
#>

[CmdletBinding()]
param(
  [ValidateSet('10.0.26100', '10.0.22621', '10.0.22000', 'auto')]
  [string]$WdkVersion = 'auto',
  [switch]$SkipWingetWdk,
  [switch]$SkipVsModify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step([string]$Message) {
  Write-Host ''
  Write-Host "=== $Message ===" -ForegroundColor Cyan
}

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-Elevation {
  if (Test-IsAdmin) { return }
  Write-Host 'Administrator rights required. Re-launching elevated (UAC)...'
  $argList = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
    '-WdkVersion', $WdkVersion
  )
  if ($SkipWingetWdk) { $argList += '-SkipWingetWdk' }
  if ($SkipVsModify) { $argList += '-SkipVsModify' }
  Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -Wait | Out-Null
  exit $LASTEXITCODE
}

function Get-VsInstallPath {
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (-not (Test-Path $vswhere)) { return $null }
  $path = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath 2>$null
  if ($path) { return $path.Trim() }
  $path = & $vswhere -latest -products Microsoft.VisualStudio.Product.Community `
    -property installationPath 2>$null
  if ($path) { return $path.Trim() }
  return $null
}

function Resolve-WdkWingetId {
  param([string]$Version)
  if ($Version -eq 'auto') {
    $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Include'
    if (Test-Path $kits) {
      $have = Get-ChildItem $kits -Directory | ForEach-Object { $_.Name }
      if ($have -contains '10.0.26100.0') { return 'Microsoft.WindowsWDK.10.0.26100' }
      if ($have -contains '10.0.22621.0') { return 'Microsoft.WindowsWDK.10.0.22621' }
      if ($have -contains '10.0.22000.0') { return 'Microsoft.WindowsWDK.10.0.22000' }
    }
    return 'Microsoft.WindowsWDK.10.0.26100'
  }
  return ("Microsoft.WindowsWDK.{0}" -f $Version)
}

Request-Elevation

Write-Step 'Environment'
$vsPath = Get-VsInstallPath
Write-Host "VS path: $(if ($vsPath) { $vsPath } else { '(not found)' })"
$winget = Get-Command winget -ErrorAction SilentlyContinue
if (-not $winget) { throw 'winget not found. Install App Installer from Microsoft Store.' }

if (-not $SkipVsModify) {
  Write-Step 'Visual Studio: add C++ / WDK integration components'
  $installer = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vs_installer.exe'
  $setup = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\setup.exe'
  if (-not (Test-Path $setup)) { $setup = $installer }
  if (-not (Test-Path $setup)) { throw 'Visual Studio Installer not found.' }
  if (-not $vsPath) { throw 'Visual Studio Community/Professional not found. Install VS first.' }

  # Component IDs for VS 2022/2026 + WDK VS integration
  $components = @(
    'Microsoft.VisualStudio.Workload.NativeDesktop',
    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
    'Microsoft.VisualStudio.Component.Windows10SDK.26100',
    'Microsoft.VisualStudio.Component.VC.Runtimes.x86.x64.Spectre',
    'Microsoft.VisualStudio.Component.VC.Runtimes.ARM64.Spectre',
    'Microsoft.VisualStudio.ComponentGroup.NativeDesktop.Core',
    'Microsoft.VisualStudio.Component.VC.ATL',
    'Microsoft.VisualStudio.Component.VC.ATLMFC',
    'Microsoft.VisualStudio.Component.WindowsDriverKit'
  )

  $addArgs = @()
  foreach ($c in $components) {
    $addArgs += '--add'
    $addArgs += $c
  }

  Write-Host "Running: $setup modify --installPath `"$vsPath`" ..."
  $p = Start-Process -FilePath $setup -ArgumentList (@(
    'modify',
    '--installPath', $vsPath,
    '--quiet',
    '--norestart',
    '--acceptAll'
  ) + $addArgs) -Wait -PassThru
  Write-Host "VS modify exit: $($p.ExitCode)"
  # 0 = success; some VS installer codes still OK (3010 reboot required)
  if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
    Write-Host "WARNING: VS modify returned $($p.ExitCode). Continuing; WDK winget may still provide the toolset."
  }
}

if (-not $SkipWingetWdk) {
  Write-Step 'winget: Windows Driver Kit'
  $wdkId = Resolve-WdkWingetId -Version $WdkVersion
  Write-Host "Package: $wdkId"
  & winget install --id $wdkId -e --accept-package-agreements --accept-source-agreements --disable-interactivity
  $wgExit = $LASTEXITCODE
  Write-Host "winget exit: $wgExit"
  # 0 success, -1978335189 already installed (varies by winget version)
  if ($wgExit -ne 0 -and $wgExit -ne -1978335189) {
    Write-Host "WARNING: winget WDK install exit $wgExit"
  }
}

Write-Step 'Verify toolset'
$msbuild = Join-Path $vsPath 'MSBuild\Current\Bin\MSBuild.exe'
if (-not (Test-Path $msbuild)) {
  $msbuild = (Get-ChildItem (Join-Path $vsPath 'MSBuild') -Recurse -Filter MSBuild.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName)
}
Write-Host "MSBuild: $msbuild"

$props = Get-ChildItem (Join-Path $vsPath 'MSBuild') -Recurse -Filter '*KernelModeDriver*' -ErrorAction SilentlyContinue |
  Select-Object -First 10 FullName
if ($props) {
  Write-Host 'Found KernelModeDriver props:'
  $props | ForEach-Object { Write-Host "  $($_.FullName)" }
} else {
  Write-Host 'WARNING: WindowsKernelModeDriver props not found yet.'
  Write-Host 'If build still fails, reboot and re-run this script, or install WDK VSIX from the WDK start menu shortcut.'
}

$buildScript = Join-Path $PSScriptRoot 'Build-SoftVol.ps1'
Write-Host ''
Write-Host 'Next:'
Write-Host "  pwsh -File `"$buildScript`""
Write-Host '  (then test-sign + Install-SoftVol.cmd)'
exit 0
