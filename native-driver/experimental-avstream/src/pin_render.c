/*++
  Pin-centric render pin — SetState drains the stream gate; Process is gated.
--*/

#include "ftd_common.h"

extern const PKSDATARANGE* FtdRenderPinDataRanges;
extern const ULONG FtdRenderPinDataRangeCount;

static NTSTATUS
FtdRenderPinCreate(
    _In_ PKSPIN Pin,
    _In_ PIRP Irp
    )
{
    PFTD_PIN_CONTEXT pinCtx;

    UNREFERENCED_PARAMETER(Irp);

    pinCtx = (PFTD_PIN_CONTEXT)ExAllocatePool2(
        POOL_FLAG_NON_PAGED,
        sizeof(*pinCtx),
        FTD_POOL_TAG);
    if (pinCtx == NULL) {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    RtlZeroMemory(pinCtx, sizeof(*pinCtx));
    FtdGateInit(&pinCtx->Gate);
    pinCtx->SampleRate = 48000;
    pinCtx->Channels = 2;
    pinCtx->BitsPerSample = 16;
    Pin->Context = pinCtx;
    return STATUS_SUCCESS;
}

static NTSTATUS
FtdRenderPinClose(
    _In_ PKSPIN Pin,
    _In_ PIRP Irp
    )
{
    PFTD_PIN_CONTEXT pinCtx = (PFTD_PIN_CONTEXT)Pin->Context;

    UNREFERENCED_PARAMETER(Irp);

    if (pinCtx != NULL) {
        FtdGateStopAndDrain(&pinCtx->Gate);
        ExFreePoolWithTag(pinCtx, FTD_POOL_TAG);
        Pin->Context = NULL;
    }
    return STATUS_SUCCESS;
}

static NTSTATUS
FtdRenderPinSetDataFormat(
    _In_ PKSPIN Pin,
    _In_opt_ PKSDATAFORMAT OldFormat,
    _In_opt_ PKSMULTIPLE_ITEM OldAttributeList,
    _In_ const KSDATARANGE *DataRange,
    _In_opt_ const KSATTRIBUTE_LIST *AttributeRange
    )
{
    PFTD_PIN_CONTEXT pinCtx = (PFTD_PIN_CONTEXT)Pin->Context;
    PKSDATAFORMAT_WAVEFORMATEX fmt;

    UNREFERENCED_PARAMETER(OldFormat);
    UNREFERENCED_PARAMETER(OldAttributeList);
    UNREFERENCED_PARAMETER(DataRange);
    UNREFERENCED_PARAMETER(AttributeRange);

    if (Pin->ConnectionFormat == NULL) {
        return STATUS_INVALID_PARAMETER;
    }

    fmt = (PKSDATAFORMAT_WAVEFORMATEX)Pin->ConnectionFormat;
    if (fmt->DataFormat.FormatSize < sizeof(KSDATAFORMAT_WAVEFORMATEX)) {
        return STATUS_INVALID_PARAMETER;
    }

    if (pinCtx != NULL) {
        pinCtx->SampleRate = fmt->WaveFormatEx.nSamplesPerSec;
        pinCtx->Channels = fmt->WaveFormatEx.nChannels;
        pinCtx->BitsPerSample = fmt->WaveFormatEx.wBitsPerSample;
    }
    return STATUS_SUCCESS;
}

static NTSTATUS
FtdRenderPinSetDeviceState(
    _In_ PKSPIN Pin,
    _In_ KSSTATE ToState,
    _In_ KSSTATE FromState
    )
{
    PFTD_PIN_CONTEXT pinCtx = (PFTD_PIN_CONTEXT)Pin->Context;

    UNREFERENCED_PARAMETER(FromState);

    if (pinCtx == NULL) {
        return STATUS_INVALID_DEVICE_STATE;
    }

    if (ToState == KSSTATE_RUN) {
        FtdGateAllowRun(&pinCtx->Gate);
    } else {
        /*
         * Drain before AVStream releases leading-edge pointers / MDLs.
         * Structural fix for the legacy AvidFastTrackDuo+0x1849d race.
         */
        FtdGateStopAndDrain(&pinCtx->Gate);
    }

    return STATUS_SUCCESS;
}

static NTSTATUS
FtdRenderPinProcess(
    _In_ PKSPIN Pin
    )
{
    PFTD_PIN_CONTEXT pinCtx = (PFTD_PIN_CONTEXT)Pin->Context;
    PKSSTREAM_POINTER leading;
    LONG cookie;
    ULONG used;

    if (pinCtx == NULL) {
        return STATUS_SUCCESS;
    }

    if (!FtdGateTryEnter(&pinCtx->Gate, &cookie)) {
        return STATUS_SUCCESS;
    }

    leading = KsPinGetLeadingEdgeStreamPointer(Pin, KSSTREAM_POINTER_STATE_LOCKED);
    if (leading == NULL) {
        FtdGateLeave(&pinCtx->Gate, cookie);
        return STATUS_SUCCESS;
    }

    used = leading->OffsetIn.Remaining;

    /*
     * TODO(USB): copy OffsetIn frames into isoch URB payloads (RenderPipe).
     * Until USB bring-up, advance frames so the graph does not stall — silence,
     * never touch buffers after gate stop.
     */
    KsStreamPointerAdvanceOffsetsAndUnlock(leading, used, 0, FALSE);

    FtdGateLeave(&pinCtx->Gate, cookie);
    return STATUS_SUCCESS;
}

static const KSPIN_DISPATCH FtdRenderPinDispatch = {
    FtdRenderPinCreate,
    FtdRenderPinClose,
    FtdRenderPinProcess,
    NULL, /* Reset */
    FtdRenderPinSetDataFormat,
    FtdRenderPinSetDeviceState,
    NULL, /* Connect */
    NULL, /* Disconnect */
    NULL, /* Clock */
    NULL  /* Allocator */
};

const KSPIN_DESCRIPTOR_EX FtdRenderPinDescriptor = {
    &FtdRenderPinDispatch,
    NULL, /* AutomationTable */
    {
        0,    /* InterfacesCount */
        NULL, /* Interfaces */
        0,    /* MediumsCount */
        NULL, /* Mediums */
        0,    /* DataRangesCount — patched in FtdInitDescriptors */
        NULL, /* DataRanges */
        KSPIN_DATAFLOW_IN,
        KSPIN_COMMUNICATION_SINK,
        &KSCATEGORY_AUDIO,
        NULL,
        0
    },
    KSPIN_FLAG_PROCESS_IN_RUN_STATE_ONLY,
    1,
    1,
    NULL,
    NULL
};

/* Mutable copy so we can fill DataRanges pointers after formats.c links. */
KSPIN_DESCRIPTOR_EX FtdRenderPinDescriptorLive;

VOID
FtdInitPinDescriptor(
    VOID
    )
{
    FtdRenderPinDescriptorLive = FtdRenderPinDescriptor;
    FtdRenderPinDescriptorLive.PinDescriptor.DataRangesCount = FtdRenderPinDataRangeCount;
    FtdRenderPinDescriptorLive.PinDescriptor.DataRanges = FtdRenderPinDataRanges;
}
