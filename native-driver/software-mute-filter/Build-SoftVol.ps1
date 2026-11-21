#Requires -Version 5.1
<#
.SYNOPSIS
  Build FtdSoftVol.sys (MSBuild WDK toolset, or cl/link fallback using Kit KM libs).
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
$Src = Join-Path $Root 'src\FtdSoftVol.c'
$OutDir = Join-Path $Root "$Configuration\$Platform"
$ObjDir = Join-Path $OutDir 'obj'

function Find-MSBuild {
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (Test-Path $vswhere) {
    $found = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' |
      Select-Object -First 1
    if ($found) { return $found }
  }
  foreach ($c in @(
    "${env:ProgramFiles}\Microsoft Visual Studio\18\Community\MSBuild\Current\Bin\MSBuild.exe",
    "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe"
  )) {
    if (Test-Path $c) { return $c }
  }
  return $null
}

function Find-VsMsvc {
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  $vs = $null
  if (Test-Path $vswhere) {
    $vs = (& $vswhere -latest -products * -property installationPath | Select-Object -First 1)
  }
  if (-not $vs) { $vs = "${env:ProgramFiles}\Microsoft Visual Studio\18\Community" }
  $msvcRoot = Join-Path $vs 'VC\Tools\MSVC'
  $ver = Get-ChildItem $msvcRoot -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Select-Object -First 1
  if (-not $ver) { throw "MSVC not found under $msvcRoot" }
  return $ver.FullName
}

function Find-KitVersion {
  $inc = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Include'
  $ver = Get-ChildItem $inc -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'km\ntddk.h') } |
    Sort-Object Name -Descending | Select-Object -First 1
  if (-not $ver) { throw 'WDK KM headers not found. Run Install-BuildTools.cmd (UAC).' }
  return $ver.Name
}

function Stage-Package([string]$SysPath) {
  $pkg = Join-Path $Root 'package'
  New-Item -ItemType Directory -Force -Path $pkg | Out-Null
  Copy-Item $SysPath (Join-Path $pkg 'FtdSoftVol.sys') -Force
  Copy-Item (Join-Path $Root 'inf\FtdSoftVol.inf') (Join-Path $pkg 'FtdSoftVol.inf') -Force
  Write-Host "OK: $SysPath"
  Write-Host "Staged: $pkg"
}

function Build-WithMsbuild {
  $msbuild = Find-MSBuild
  if (-not $msbuild) { return $false }
  Write-Host "Trying MSBuild toolset: $msbuild"
  # Capture MSB8020 (missing WindowsKernelModeDriver10.0) without stopping the script
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  & $msbuild $Sln /p:Configuration=$Configuration /p:Platform=$Platform /v:m 2>&1 | Out-Host
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  if ($code -ne 0) {
    Write-Host "MSBuild failed ($code); will try cl/link fallback."
    return $false
  }
  foreach ($cand in @(
    (Join-Path $Root "$Configuration\$Platform\FtdSoftVol.sys"),
    (Join-Path $Root "x64\$Configuration\FtdSoftVol.sys")
  )) {
    if (Test-Path $cand) {
      Stage-Package $cand
      return $true
    }
  }
  return $false
}

function Build-WithClLink {
  Write-Host 'Falling back to cl.exe / link.exe with WDK KM libs...'
  $msvc = Find-VsMsvc
  $kitVer = Find-KitVersion
  $kitRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
  $cl = Join-Path $msvc 'bin\Hostx64\x64\cl.exe'
  $link = Join-Path $msvc 'bin\Hostx64\x64\link.exe'
  if (-not (Test-Path $cl)) { throw "cl.exe not found: $cl" }

  New-Item -ItemType Directory -Force -Path $ObjDir | Out-Null
  $obj = Join-Path $ObjDir 'FtdSoftVol.obj'
  $sys = Join-Path $OutDir 'FtdSoftVol.sys'
  $pdb = Join-Path $OutDir 'FtdSoftVol.pdb'

  $incKm = Join-Path $kitRoot "Include\$kitVer\km"
  $incShared = Join-Path $kitRoot "Include\$kitVer\shared"
  $incUcrt = Join-Path $kitRoot "Include\$kitVer\ucrt"
  $incMsvc = Join-Path $msvc 'include'
  $libKm = Join-Path $kitRoot "Lib\$kitVer\km\x64"

  if (-not (Test-Path $incUcrt)) {
    throw "UCRT headers missing: $incUcrt"
  }

  $bufOverflow = Join-Path $libKm 'BufferOverflowFastFailK.lib'
  if (-not (Test-Path $bufOverflow)) {
    $bufOverflow = Join-Path $libKm 'BufferOverflowK.lib'
  }

  Write-Host "MSVC: $msvc"
  Write-Host "Kit:  $kitVer"
  Write-Host "Out:  $sys"

  $clArgs = @(
    '/c', '/nologo', '/kernel', '/GS', '/W4', '/Zi', '/Od',
    '/D_WIN64', '/D_AMD64_', '/DAMD64', '/DDEPRECATE_DDK_FUNCTIONS=1',
    "/I$incKm", "/I$incShared", "/I$incUcrt", "/I$incMsvc",
    "/I$(Join-Path $Root 'include')",
    "/Fo$obj", "/Fd$(Join-Path $ObjDir 'vc.pdb')",
    $Src
  )
  Write-Host "cl $($clArgs -join ' ')"
  & $cl @clArgs
  if ($LASTEXITCODE -ne 0) { throw "cl.exe failed ($LASTEXITCODE)" }

  $linkArgs = @(
    '/nologo', '/DRIVER', '/SUBSYSTEM:NATIVE', '/ENTRY:GsDriverEntry',
    '/NODEFAULTLIB', '/MANIFEST:NO', '/DEBUG',
    "/OUT:$sys", "/PDB:$pdb",
    "/LIBPATH:$libKm",
    $obj,
    'ntoskrnl.lib', 'hal.lib', 'wmilib.lib'
  )
  if (Test-Path $bufOverflow) {
    $linkArgs += $bufOverflow
  }
  Write-Host "link $($linkArgs -join ' ')"
  & $link @linkArgs
  if ($LASTEXITCODE -ne 0) { throw "link.exe failed ($LASTEXITCODE)" }
  if (-not (Test-Path $sys)) { throw "Build produced no $sys" }
  Stage-Package $sys
}

if (-not (Build-WithMsbuild)) {
  Build-WithClLink
}
