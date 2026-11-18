/*++
  KS device dispatch — PnP start/stop hooks and USB config placeholder.
--*/

#include "ftd_common.h"
#include "usb_audio.h"

static NTSTATUS
FtdDeviceAdd(
    _In_ PKSDEVICE Device
    )
{
    PFTD_DEVICE_CONTEXT ctx;

    ctx = (PFTD_DEVICE_CONTEXT)ExAllocatePool2(
        POOL_FLAG_NON_PAGED,
        sizeof(*ctx),
        FTD_POOL_TAG);
    if (ctx == NULL) {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    RtlZeroMemory(ctx, sizeof(*ctx));
    ctx->PhysicalDeviceObject = Device->PhysicalDeviceObject;
    ctx->NextLowerDeviceObject = Device->NextDeviceObject;
    Device->Context = ctx;
    return STATUS_SUCCESS;
}

static VOID
FtdDeviceRemove(
    _In_ PKSDEVICE Device
    )
{
    PFTD_DEVICE_CONTEXT ctx = (PFTD_DEVICE_CONTEXT)Device->Context;
    if (ctx != NULL) {
        ExFreePoolWithTag(ctx, FTD_POOL_TAG);
        Device->Context = NULL;
    }
}

static NTSTATUS
FtdDeviceStart(
    _In_ PKSDEVICE Device,
    _In_ PIRP Irp,
    _In_opt_ PCM_RESOURCE_LIST Translated,
    _In_opt_ PCM_RESOURCE_LIST Untranslated
    )
{
    PFTD_DEVICE_CONTEXT ctx = (PFTD_DEVICE_CONTEXT)Device->Context;

    UNREFERENCED_PARAMETER(Irp);
    UNREFERENCED_PARAMETER(Translated);
    UNREFERENCED_PARAMETER(Untranslated);

    if (ctx == NULL) {
        return STATUS_INVALID_DEVICE_STATE;
    }

    /*
     * USB bring-up is stubbed (see usb_audio.c). Start still succeeds so
     * filter factories register; pin Process stays gated and silent.
     */
    return FtdUsbConfigure(ctx, Device->NextDeviceObject);
}

static NTSTATUS
FtdDeviceStop(
    _In_ PKSDEVICE Device,
    _In_ PIRP Irp
    )
{
    PFTD_DEVICE_CONTEXT ctx = (PFTD_DEVICE_CONTEXT)Device->Context;

    UNREFERENCED_PARAMETER(Irp);

    if (ctx != NULL) {
        FtdUsbRelease(ctx);
    }
    return STATUS_SUCCESS;
}

const KSDEVICE_DISPATCH FtdDeviceDispatch = {
    FtdDeviceAdd,       /* Add */
    FtdDeviceStart,     /* Start */
    NULL,               /* PostStart */
    NULL,               /* QueryStop */
    NULL,               /* CancelStop */
    FtdDeviceStop,      /* Stop */
    NULL,               /* QueryRemove */
    NULL,               /* CancelRemove */
    FtdDeviceRemove,    /* Remove */
    NULL,               /* QueryCapabilities */
    NULL,               /* SurpriseRemoval */
    NULL,               /* QueryPower */
    NULL,               /* SetPower */
    NULL                /* QueryInterface */
};

DEFINE_KSFILTER_DESCRIPTOR_TABLE(FtdFilterDescriptors) {
    &FtdRenderFilterDescriptor
};

const KSDEVICE_DESCRIPTOR FtdDeviceDescriptor = {
    &FtdDeviceDispatch,
    SIZEOF_ARRAY(FtdFilterDescriptors),
    FtdFilterDescriptors,
    KSDEVICE_DESCRIPTOR_VERSION
};
