# Fast Track Duo — software mute / volume filter (prototype)

## What this is

`FtdSoftVol.sys` is a **WDM upper filter** above Microsoft **`usbaudio.sys`**.
It hides `KSNODETYPE_VOLUME` and `KSNODETYPE_MUTE` from the KS topology so the
Windows Audio Engine uses **software mute and volume** instead of Duo’s USB
Feature Unit (which often does not follow the Windows mute button).

This keeps the **bug-avoidance** property of the USB Audio path:

- **No** `AvidFastTrackDuo.sys` → no known `+0x1849d` BSoD site
- INF still skips Home Theater SysFx → silence-class APO mitigation retained

Physical knobs / analog gain on the hardware remain independent.

## Layout

```text
software-mute-filter/
  include/FtdSoftVol.h
  src/FtdSoftVol.c
  inf/FtdSoftVol.inf
  FtdSoftVol.vcxproj / FtdSoftVol.sln
  Install-SoftVol.ps1 / .cmd
  Verify-SoftVol.ps1
  package/                 # created by installer (sys + inf copy)
```

## Build (WDK)

Requires Visual Studio 2022 + Windows Driver Kit.

```powershell
cd native-driver\software-mute-filter
msbuild FtdSoftVol.sln /p:Configuration=Release /p:Platform=x64
```

Output (typical): `Release\x64\FtdSoftVol.sys`

### Test-sign (development)

```powershell
# One-time machine setup
bcdedit /set testsigning on
# reboot

$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=FtdSoftVol Test" `
  -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddYears(5)
$cer = Export-Certificate -Cert $cert -FilePath FtdSoftVolTest.cer
Import-Certificate -FilePath $cer.FullName -CertStoreLocation Cert:\LocalMachine\Root
Import-Certificate -FilePath $cer.FullName -CertStoreLocation Cert:\LocalMachine\TrustedPublisher

Set-AuthenticodeSignature Release\x64\FtdSoftVol.sys $cert -HashAlgorithm SHA256
```

Production / Secure Boot without testsigning needs **EV + WHCP** attestation — not part of this prototype.

## Install

1. Prefer having Duo already on `usbaudio` (`..\usbaudio\Install-UsbAudio.cmd`), or let this INF rebinding happen together.
2. Elevated:

```powershell
.\Install-SoftVol.cmd
.\Verify-SoftVol.ps1
```

3. Reboot if Verify shows missing UpperFilters or the service did not attach.
4. Play audio → toggle **Windows mute** / volume. Shared-mode apps should follow software mute.

## Uninstall

```powershell
pnputil /enum-drivers   # find published oemXX.inf for FtdSoftVol.inf
pnputil /delete-driver oemXX.inf /uninstall /force
# Then re-run ..\usbaudio\Install-UsbAudio.cmd if you want class driver without the filter
```

## Limits (prototype)

- Kernel filter: **testsigning or WHCP** required
- Topology rewrite assumes a typical USB-audio node graph; odd topologies may need more bridging rules
- Does not restore Avid control-panel / mixer features
- Not packaged into `Fast-Track-Duo-USBAudio.exe` yet (source + scripts only)

## Related

- Supported class-driver bind (no filter): [`../usbaudio/`](../usbaudio/)
- Custom AVStream research scaffold: [`../experimental-avstream/`](../experimental-avstream/)
