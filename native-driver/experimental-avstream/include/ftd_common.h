/*++
  FastTrackDuoNew — shared types and pool tags.
  Target: WDM AVStream USB audio minidriver (WIP).
--*/

#pragma once

#include <ntddk.h>
#include <ks.h>
#include <ksmedia.h>
#include <usb.h>
#include <usbdlib.h>

#ifndef FTD_POOL_TAG
#define FTD_POOL_TAG 'dTFN' /* N F T d */
#endif

#define FTD_SERVICE_NAME L"FTDUSBNEW"
#define FTD_BINARY_NAME  L"FastTrackDuoNew.sys"

/* Hardware ID matches official Duo audio interface function. */
#define FTD_USB_VID 0x0B0F
#define FTD_USB_PID 0x2036
#define FTD_USB_MI  0x00

/* Filter reference string GUID — must match INF AddInterface reference. */
DEFINE_GUIDSTRUCT("8F3E2A71-9C4B-4D6E-B2A1-7E5D9F0C3A18", FTD_RENDER_FILTER_REFERENCE);
#define FTD_RENDER_FILTER_REFERENCE DEFINE_GUIDNAMED(FTD_RENDER_FILTER_REFERENCE)

/* stream_gate.c */
typedef struct _FTD_STREAM_GATE {
    volatile LONG Generation;
    volatile LONG InFlight;
    volatile LONG Running; /* 0 = stopped, 1 = run */
    KEVENT DrainEvent;
} FTD_STREAM_GATE, *PFTD_STREAM_GATE;

typedef struct _FTD_DEVICE_CONTEXT {
    PDEVICE_OBJECT PhysicalDeviceObject;
    PDEVICE_OBJECT NextLowerDeviceObject;
    USB_DEVICE_DESCRIPTOR UsbDeviceDescriptor;
    USBD_CONFIGURATION_HANDLE ConfigurationHandle;
    BOOLEAN UsbConfigured;
    /* Isoch pipe handles filled during USB bring-up (TODO). */
    USBD_PIPE_HANDLE RenderPipe;
} FTD_DEVICE_CONTEXT, *PFTD_DEVICE_CONTEXT;

typedef struct _FTD_PIN_CONTEXT {
    FTD_STREAM_GATE Gate;
    ULONG SampleRate;
    ULONG Channels;
    ULONG BitsPerSample;
} FTD_PIN_CONTEXT, *PFTD_PIN_CONTEXT;

VOID FtdGateInit(_Out_ PFTD_STREAM_GATE Gate);
BOOLEAN FtdGateTryEnter(_Inout_ PFTD_STREAM_GATE Gate, _Out_ LONG *Cookie);
VOID FtdGateLeave(_Inout_ PFTD_STREAM_GATE Gate, _In_ LONG Cookie);
VOID FtdGateAllowRun(_Inout_ PFTD_STREAM_GATE Gate);
VOID FtdGateStopAndDrain(_Inout_ PFTD_STREAM_GATE Gate);

/* device.c */
extern const KSDEVICE_DISPATCH FtdDeviceDispatch;
extern const KSDEVICE_DESCRIPTOR FtdDeviceDescriptor;

/* filter / pin */
extern KSFILTER_DESCRIPTOR FtdRenderFilterDescriptor;
extern VOID FtdInitPinDescriptor(VOID);
