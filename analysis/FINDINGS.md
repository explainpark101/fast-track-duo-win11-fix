# Fast Track Duo 1.0.4 — root-cause findings

Sanitized evidence ledger (no host paths, usernames, or machine instance IDs).

## Package / driver

| Item | Observation |
|------|-------------|
| Package | Official installer zip → PE launcher (2013-05-25) → MSI64 CAB |
| Kernel driver | `AvidFastTrackDuo.sys` **5.10.0.3505** (WinDDK) |
| USB hardware ID | `USB\VID_0B0F&PID_2036&MI_00` |
| Service name | `AVIDUSBFASTTRACKDUO` |
| Stock INF FX | `Needs=...,mssysfx.CopyFilesAndRegister` + `FX\0` Premix/Postmix CLSIDs for **Microsoft Audio Home Theater Effects** |

## BSOD (kernel triage dump)

Representative `!analyze -v` excerpt (module / offset only):

```
IMAGE_NAME:   AvidFastTrackDuo.sys
SYMBOL_NAME:  AvidFastTrackDuo+1849d
IP_IN_PAGED_CODE:
  AvidFastTrackDuo+1849d
  add eax, dword ptr [rbx]
PROCESS_NAME: System
FAILURE_BUCKET_ID: AV_AvidFastTrackDuo!unknown_function
```

Event Log style codes seen across dumps:

- `0xD1` `DRIVER_IRQL_NOT_LESS_OR_EQUAL` (Arg2 = `2` = DISPATCH_LEVEL)
- `0xA` `IRQL_NOT_LESS_OR_EQUAL`

Multiple dumps faulted at the **same** module offset: `AvidFastTrackDuo+0x1849d`.

### Instruction context (file RVA `0x1849d`)

Raw bytes begin `03 03 48 83 c3 04 c1 f8 08 …` — a render-path sample conversion loop reading little-endian PCM dwords from `rbx`.

**Inference:** after a browser WASAPI client tears down quickly (tab close / URL change), DPC/stream code still dereferences a freed or paged buffer at elevated IRQL (use-after-free / invalid non-resident access).

## Silence ↔ Spatial Sound

Stock INF attaches legacy Home Theater LFX/GFX APOs. Toggling Spatial Sound forces Audio Engine / APO remount, matching “total silence until Spatial toggle restores audio.”

SysFx may already be disabled (`PKEY_AudioEndpoint_Disable_SysFx = 1`) while FX CLSID values remain — incomplete cleanup unless DeviceClasses `FX\0` / `MSFX` and the published INF are fixed.

## What the patch changes vs what it cannot

| Layer | Action | Notes |
|-------|--------|--------|
| DeviceClasses `FX\0` / `MSFX` | Remove for Duo USB ID | Done by installer (discovered at runtime) |
| DriverStore + published `oem*.inf` | Replace with `AvidFastTrackDuo.nofx.inf` | Omits `mssysfx` / `FX\0` |
| MMDevices SysFx | Set disable DWORD = 1 on Duo render endpoints | Discovered by friendly name |
| `AvidFastTrackDuo.sys` | No binary edit | Real UAF fix needs WHCP-signed rebuild |

## Static notes

Installer graph: zip → PE launcher → MSI64 → `StreamingSYS` (= `AvidFastTrackDuo.sys`). Imports include `ks.sys` stream-pointer APIs, DPC-level queued spinlocks, `KeBugCheckEx`, contiguous DMA helpers — consistent with a 2013 USB Audio KS minidriver.
