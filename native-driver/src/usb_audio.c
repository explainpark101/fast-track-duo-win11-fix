/*++
  USB configuration — stub until real Duo descriptors are wired.
--*/

#include "usb_audio.h"

NTSTATUS
FtdUsbConfigure(
    _Inout_ PFTD_DEVICE_CONTEXT Ctx,
    _In_ PDEVICE_OBJECT NextLower
    )
{
    UNREFERENCED_PARAMETER(NextLower);

    /*
     * Milestone plan:
     *  - GET_DESCRIPTOR device + full configuration
     *  - Find AudioControl + AudioStreaming interfaces for MI_00
     *  - SELECT_CONFIGURATION / SELECT_INTERFACE for isoch OUT alt
     *  - Store RenderPipe for pin Process
     */
    Ctx->UsbConfigured = FALSE;
    Ctx->RenderPipe = NULL;
    Ctx->ConfigurationHandle = NULL;
    return STATUS_SUCCESS;
}

VOID
FtdUsbRelease(
    _Inout_ PFTD_DEVICE_CONTEXT Ctx
    )
{
    Ctx->UsbConfigured = FALSE;
    Ctx->RenderPipe = NULL;
    Ctx->ConfigurationHandle = NULL;
}
