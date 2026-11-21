# Fast Track Duo — new driver (USB Audio Class)

## Goal

Replace Avid’s 2013 `AvidFastTrackDuo.sys` (BSoD at `+0x1849d`) with a driver
stack you can **install and use for real audio**.

## What actually works

| Path | Role |
|------|------|
| **[`usbaudio/`](usbaudio/)** | **Supported.** Rebind `USB\VID_0B0F&PID_2036&MI_00` to Microsoft **`usbaudio.sys`** (UAC 1.0), no Home Theater SysFx in our INF. |
| [`software-mute-filter/`](software-mute-filter/) | **Prototype.** Same `usbaudio` bind + `FtdSoftVol.sys` upper filter that hides hardware VOLUME/MUTE so Windows uses **software mute/volume**. Needs WDK build + testsigning/WHCP. |
| [`experimental-avstream/`](experimental-avstream/) | Research scaffold for a custom `.sys`. Needs WDK + WHCP. Not installable for daily use. |

### Why inbox `usbaudio.sys`?

On this hardware Windows already reports compatible IDs:

```text
USB\Class_01&SubClass_01&Prot_00
USB\Class_01&SubClass_01
USB\Class_01
```

`pnputil /enum-devices ... /drivers` shows **`wdma_usb.inf` / usbaudio** as a
matching driver, **outranked** only by Avid’s VID/PID package. Avid documents
Duo as **class-compliant on Mac**. The proprietary Windows `.sys` is not required
for basic PCM I/O; it is what introduces the known kernel UAF under modern
WASAPI teardown.

## Install

**Release binary (preferred for end users):** `dist/Fast-Track-Duo-USBAudio.exe`
(from GitHub Releases / `packaging/build.ps1`). Same payload as this folder.

From source:

1. Close audio apps.
2. Run elevated: [`usbaudio/Install-UsbAudio.cmd`](usbaudio/Install-UsbAudio.cmd)
3. If Verify still shows Avid: **reboot once**, then run the installer again
   (package delete often needs a reboot on Win11).
4. Confirm Device Manager → Fast Track Duo → Driver:
   - **Driver provider:** Microsoft
   - **Service:** `usbaudio` (not `AVIDUSBFASTTRACKDUO`)
5. Spatial sound **Off**, disable Enhancements.
6. If Firefox/Chrome silence each other intermittently, run elevated
   [`usbaudio/Harden-DuoSharedAudio.cmd`](usbaudio/Harden-DuoSharedAudio.cmd)
   (disables exclusive mode + SysFx, restarts Audio).
7. Play/record a short clip.

The installer deletes Avid `oem*.inf`, then `pnputil /add-driver` on the
inbox DriverStore `wdma_usb.inf` (this OS has no `/update-driver`). Unsigned
community OEM INF is optional (`-TryOemInf`) and usually rejected.

## Uninstall / return to Avid 1.0.4

Reinstall official Avid 1.0.4, or use this repo’s `driver/1.0.5` /
`1.0.4-patch` packages if you still need the old stack + INF hardening.

## Layout

```text
native-driver/
  usbaudio/                  # installable class-driver binding
    FastTrackDuoUsbAudio.inf
    Install-UsbAudio.ps1
    Install-UsbAudio.cmd
  software-mute-filter/      # prototype: usbaudio + software mute/volume filter
    FtdSoftVol.sys sources, INF, Install-SoftVol.ps1
  experimental-avstream/     # custom KS .sys scaffold (WDK)
```

## Optional: Windows mute / volume via software path

If inbox `usbaudio` leaves Windows mute ineffective (hardware Feature Unit),
build and install the prototype filter:

```powershell
# after WDK build + test-sign of FtdSoftVol.sys
sudo .\software-mute-filter\Install-SoftVol.cmd
.\software-mute-filter\Verify-SoftVol.ps1
```

Details: [`software-mute-filter/README.md`](software-mute-filter/README.md).
