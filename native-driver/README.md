# Fast Track Duo — new AVStream USB audio driver (WIP)

Experimental **from-scratch** kernel minidriver intended to replace the 2013
`AvidFastTrackDuo.sys` path for `USB\VID_0B0F&PID_2036&MI_00`.

This is **not** a binary patch of Avid’s image. Goal: fix the known render-path
use-after-free (legacy `+0x1849d`) by owning stream lifetime explicitly, and
ship without Home Theater APO registration.

## Status

| Area | State |
|------|--------|
| Branch scaffold (AVStream descriptors, INF, stream gate) | **Started** |
| USB configuration / isochronous pipes | TODO |
| PCM format negotiation vs real Duo descriptors | TODO (stubs: 44.1/48 kHz, 16-bit stereo) |
| Capture / mixer / MIDI | TODO |
| Production code signing + WHCP | Blocked (needs EV cert + attestation) |

Existing INF/APO mitigations under `patch/` and `driver/1.0.5/` remain the
supported user-facing fix until this driver can stream and be signed.

## Design notes

1. **Stack**: WDM + AVStream (`KsInitializeDriver`), same class of driver as the
   original package, so Windows Audio / WASAPI can bind via KS pins.
2. **UAF mitigation**: `stream_gate.c` uses a generation counter + in-flight
   count. Pin `SetState(STOP)` drains in-flight `Process` callbacks **before**
   any buffer/MDL teardown. `Process` must not touch stream buffers unless
   `FtdGateTryEnter` succeeds.
3. **INF**: no `mssysfx` / `FX\0` Home Theater entries (silence class of bugs).
4. **Service / binary names** are new (`FTDUSBNEW` / `FastTrackDuoNew.sys`) so
   they do not overwrite Avid’s Authenticode-signed package accidentally.

## Build (local WDK)

Requires [Windows Driver Kit](https://learn.microsoft.com/windows-hardware/drivers/download-the-wdk)
and Visual Studio with the **WindowsKernelModeDriver10.0** platform toolset
(Spectre-mitigated libs matching your WDK). Without the WDK VS extension, MSBuild
fails with `MSB8020` (toolset not found) — that is expected on a stock IDE install.

```text
msbuild native-driver\FastTrackDuoNew.sln /p:Configuration=Release /p:Platform=x64
```

Output (typical): `native-driver\x64\Release\FastTrackDuoNew.sys`

Do **not** install on a daily driver without test signing / a spare machine.

## Test install (testsigning only)

1. Enable test signing, reboot, turn Memory Integrity off if the unsigned package is rejected.
2. Remove or disable the stock Avid package for MI_00 if it owns the device.
3. `pnputil /add-driver native-driver\inf\FastTrackDuoNew.inf /install`
4. Verify Bug Check `0xD1` / `0xA` at the old Avid offset no longer appears (new
   binary will have different symbols; watch for any new fault in `FastTrackDuoNew`).

## Hardware ID

```text
USB\VID_0B0F&PID_2036&MI_00
```

`MI_03` / `MI_04` HID interfaces stay on the inbox HID stack.

## Next implementation milestones

1. Parse Duo configuration descriptors; select audio streaming alt-settings.
2. Isoch OUT (render) URB cycle with non-paged bounce buffers.
3. Wire pin `Process` to copy KS frames → URB payloads under the stream gate.
4. Capture (isoch IN) + clock.
5. Match real supported rates/bit depths from hardware (replace format stubs).
6. Sign + WHCP if ever distributed broadly.
