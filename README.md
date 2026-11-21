<img src="assets/icon.svg" width="64" height="64" alt="">

# Fast-Track-Duo-Fix

**Language:** English · [한국어](README.ko.md)

## Recommended: Microsoft USB Audio (`usbaudio.sys`)

Duo is **USB Audio Class 1.0**. The 2013 Avid package (`AvidFastTrackDuo.sys`) outranks Windows’ inbox driver and is what causes the known **BSoD** (`+0x1849d`) under modern WASAPI teardown. **Preferred fix:** stop using that `.sys` and bind **Microsoft `usbaudio.sys`**.

| Release file | Action |
|--------------|--------|
| **`Fast-Track-Duo-USBAudio.exe`** | **Install this (recommended).** Removes Avid OEM ranking and binds inbox USB Audio. |

```text
1. Run Fast-Track-Duo-USBAudio.exe (UAC)
2. Reboot if Windows says so / if Verify fails, then run again if needed
3. Confirm service = usbaudio  (not AVIDUSBFASTTRACKDUO)
4. Spatial sound Off · Enhancements disabled · prefer USB 2.0
```

From a git checkout (same installer logic):

```powershell
sudo .\native-driver\usbaudio\Install-UsbAudio.cmd
.\native-driver\usbaudio\Verify-UsbAudio.ps1   # PASS: bound to usbaudio
```

Details: [`native-driver/README.md`](native-driver/README.md) · full chooser: [`RELEASE_NOTES.md`](RELEASE_NOTES.md).

---

Mitigations for **intermittent silence** and **audio-related BSoD** with official Avid **1.0.4** (`AvidFastTrackDuo.sys` 5.10.0.3505, 2013) on Windows 10/11.

## Downloads (GitHub Releases)

Tag a version (`v1.0.0`, …) or run the **Release packages** workflow.

| File | Use when |
|------|----------|
| **`Fast-Track-Duo-USBAudio.exe`** | **Default.** Replace Avid `.sys` with Microsoft USB Audio class driver |
| **`1.0.4-patch.exe`** | Keep official **1.0.4** `.sys` — INF / APO hardening only |
| **`Fast-Track-Duo-Driver_fix.1.0.0.exe`** | Community **driver 1.0.5** clean install (fixed INF + **original Avid `.sys`**) |

Build locally:

```powershell
pwsh -File packaging/build.ps1
# outputs under dist\  (includes Fast-Track-Duo-USBAudio.exe)
```

## Symptoms → causes (short)

| Symptom | Cause |
|---------|--------|
| While Chrome/Firefox is playing media, closing a tab or changing the URL sometimes kills **all** sound. Toggling Spatial Sound brings audio back | Stock INF attaches **Microsoft Audio Home Theater Effects** (`mssysfx` / `FX\0`). Spatial / APO remount unsticks a broken userspace audio graph |
| BSoD while changing a Firefox tab URL during streaming | Kernel driver `AvidFastTrackDuo.sys` at offset **`+0x1849d`** reads a bad/paged buffer at DISPATCH_LEVEL (`0xD1` / `0xA`) |

Evidence excerpts omit host paths, accounts, and device instance IDs. Full ledger: [analysis/FINDINGS.md](analysis/FINDINGS.md).

---

## Why this happens (detailed)

### 1. The driver is a 2013 USB Audio KS minidriver on a 2020s OS

Fast Track Duo’s Windows package ships a WDM/Kernel Streaming minidriver (`AvidFastTrackDuo.sys`) built with the era’s WinDDK, plus an INF that wires it into Windows’ audio stack. That design assumes:

- slower, less aggressive client teardown than modern Chromium/Gecko media stacks
- the older “system effects” (LFX/GFX) model, not today’s Spatial Sound + APO graph
- code-signing / WHCP rules that still accepted cross-signed kernel drivers

Windows 11 still loads the binary on many machines, but the **lifetime and concurrency assumptions no longer match** how browsers open and close WASAPI streams.

### 2. BSoD: use-after-free / invalid buffer at elevated IRQL

When a tab navigates or closes, the browser tears down its WASAPI client quickly. Windows stops the pin/stream and frees or pages related buffers. The Duo driver’s render path can still run a **sample-conversion loop** on a DPC / high-IRQL path.

Sanitized WinDbg excerpt from a triage dump:

```
IMAGE_NAME:   AvidFastTrackDuo.sys
SYMBOL_NAME:  AvidFastTrackDuo+1849d
IP_IN_PAGED_CODE:
  AvidFastTrackDuo+1849d
  add eax, dword ptr [rbx]
PROCESS_NAME: System
FAILURE_BUCKET_ID: AV_AvidFastTrackDuo!unknown_function
```

At file RVA `0x1849d`, bytes start `03 03 48 83 c3 04 c1 f8 08 …` — essentially “read a PCM dword from `[rbx]`, pack it into an output buffer.” If `rbx` already points at freed or non-resident memory while IRQL is DISPATCH_LEVEL (`2`), the CPU takes a page fault that Windows turns into:

- `0xD1` `DRIVER_IRQL_NOT_LESS_OR_EQUAL`, or
- `0xA` `IRQL_NOT_LESS_OR_EQUAL`

Multiple dumps hit the **same** offset `AvidFastTrackDuo+0x1849d`. That is strong evidence of a stable bug site in the proprietary `.sys`, not a one-off memory flake.

So the BSoD is not “Firefox being broken”; it is **legacy kernel audio code racing stream teardown** under modern browser load patterns.

### 3. Silence: legacy Home Theater APOs vs Spatial Sound

Separately from the kernel UAF, the **stock INF** registers Microsoft’s old Home Theater effect chain on the render interface:

```
Needs=KS.Registration,WDMAUDIO.Registration,mssysfx.CopyFilesAndRegister
...
HKR,"FX\\0",%PKEY_FriendlyName%,,%FX_FriendlyName%
HKR,"FX\\0",%PKEY_FX_PreMixClsid%,,%FX_PREMIX_CLSID%
HKR,"FX\\0",%PKEY_FX_PostMixClsid%,,%FX_POSTMIX_CLSID%
...
FX_FriendlyName = "Microsoft Audio Home Theater Effects"
```

Those entries land under DeviceClasses (`FX\0`, often mirrored as `MSFX`) and feed MMDevices `FxProperties`. On Windows 10/11 this sits next to **Spatial Sound** and the modern APO pipeline.

A plausible failure mode matching the user-visible bug:

1. Browser stops a stream mid-graph (tab close / navigation).
2. Shared-mode Audio Engine + legacy FX + Spatial processing leave the endpoint graph in a stuck state (no audible output for *any* app).
3. Changing Spatial Sound forces a remount of the APO / endpoint configuration → sound returns until the next bad teardown.

Disabling SysFx alone is often incomplete: the disable DWORD can be `1` while Premix/Postmix CLSIDs and DeviceClasses `FX\0` still exist, so the broken attach path remains.

### 4. Why “just patch the .sys” is not a drop-in fix

Fixing `+0x1849d` inside Avid’s binary means a **WHCP-attested** rebuild. This repo therefore:

- **Recommended:** **`Fast-Track-Duo-USBAudio.exe`** — bind Microsoft `usbaudio.sys` (no Avid `.sys`, so that UAF site is not loaded)
- still ships **1.0.4-patch** / **driver 1.0.5** for users who must keep the proprietary stack (INF/APO only)
- does **not** redistribute a hacked unsigned `.sys` binary patch

---

## Install

### A) Recommended → USB Audio class

1. Run **`Fast-Track-Duo-USBAudio.exe`** (UAC).
2. Reboot if Windows requires it; confirm service **`usbaudio`**.
3. Spatial Off + Enhancements Off; prefer USB 2.0.

Source: [`native-driver/usbaudio`](native-driver/usbaudio).

### B) Keep official 1.0.4 → patch only

1. Run **`1.0.4-patch.exe`** (UAC).
2. Spatial Off + Enhancements Off.

Source: [`patch/Install-Patch.cmd`](patch/Install-Patch.cmd).

### C) Clean install → driver fix 1.0.0 (still Avid `.sys`)

1. Run **`Fast-Track-Duo-Driver_fix.1.0.0.exe`** (UAC).
2. May need Memory Integrity off / testsigning (modified INF, no matching CAT).

### After install (once)

1. **Settings → System → Sound → Duo → Spatial sound = Off**
2. Sound Control Panel → Duo → **Enhancements → Disable all**
3. After a major Windows update, re-check with `Verify-UsbAudio.ps1` or re-run the matching exe if symptoms return

---

## Repository layout

```
native-driver/usbaudio/              # recommended Microsoft usbaudio bind (+ release EXE payload)
native-driver/software-mute-filter/  # prototype: usbaudio + software mute/volume upper filter
patch/                               # 1.0.4 in-place patch sources
driver/1.0.5/                        # community driver 1.0.5 (INF + official .sys/.cat)
packaging/                           # ExeHost + build.ps1 → dist/*.exe
.github/workflows/                   # tag/manual → GitHub Release upload
analysis/FINDINGS.md
README.md / README.ko.md
```

## Limits

- **`Fast-Track-Duo-USBAudio.exe`** avoids the Avid `.sys` UAF by not loading it; class-driver feature parity may differ from the 2013 package.
- Legacy patch / 1.0.5 paths **do not** repair `+0x1849d` inside `.sys`.
- Full **Driver_fix** exe may need relaxed driver signature policy (modified INF).
- **`software-mute-filter`** is a WDK prototype (testsigning/WHCP); not in the release EXE yet. See [`native-driver/software-mute-filter/README.md`](native-driver/software-mute-filter/README.md).
