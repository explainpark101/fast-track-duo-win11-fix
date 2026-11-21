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

## One-shot local setup (UAC / PIN)

No password file needed — approve interactive UAC (PIN OK if Windows offers it).

```powershell
cd native-driver\software-mute-filter

# 1) WDK + VS bits (UAC)
.\Install-BuildTools.cmd

# 2) Build .sys (no admin) — uses cl/link if VS WDK toolset missing
pwsh -File .\Build-SoftVol.ps1

# 3) Test-sign + attach UpperFilter on Duo (UAC)
.\Sign-And-Install-SoftVol.cmd

# 4) Check
pwsh -File .\Verify-SoftVol.ps1
```

If `bcdedit` just enabled testsigning for the first time, **reboot once**, then re-run step 3.

Play audio → toggle **Windows mute** / volume. Shared-mode apps should follow software mute.

### If mute/volume still do nothing

On Intel laptops, **Intel Smart Sound Technology for USB Audio** (`IntcUSB`) often
proxies Duo. Windows volume then never hits `usbaudio` / `FtdSoftVol`.

```powershell
.\Disable-IntelSstUsb.cmd   # UAC — sets device disabled (ConfigFlags)
# reboot once if Device Manager still shows SST USB Audio as OK
.\Verify-SoftVol.ps1        # should PASS without SST WARN
```

Or Device Manager → Sound, video and game controllers →
**USB 오디오용 인텔® 스마트 사운드 기술** → Disable → reboot.

## Build details

`Build-SoftVol.ps1` tries MSBuild `WindowsKernelModeDriver10.0`, then falls back to
`cl.exe` / `link.exe` with WDK KM headers (`10.0.26100.0`).

Output: `Release\x64\FtdSoftVol.sys` (also staged under `package\`).

Production / Secure Boot without testsigning needs **EV + WHCP** — not this prototype.

## Install notes

`Sign-And-Install-SoftVol.ps1` (elevated):

1. Ensures testsigning
2. Test-signs `FtdSoftVol.sys`
3. Copies to `%SystemRoot%\System32\drivers\`
4. Creates kernel service `FtdSoftVol`
5. Sets device `UpperFilters` on `USB\VID_0B0F&PID_2036&MI_00`
6. Restarts the device

(Inf2Cat driver-store packaging is skipped on this host — WDK Inf2Cat hits `0x8007000B`.)
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
