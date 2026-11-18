/*++
  USB configuration helpers for the experimental custom .sys.

  Production installs should use ../usbaudio (Microsoft usbaudio.sys).
  This module is only for a future WHCP-signed custom minidriver.
--*/

#include "usb_audio.h"

#define FTD_UAC_SUBCLASS_AUDIOCONTROL   0x01
#define FTD_UAC_SUBCLASS_AUDIOSTREAMING 0x02
#define FTD_USB_ENDPOINT_TYPE_ISOCH     0x01

typedef struct _FTD_PIPE_CANDIDATE {
    UCHAR EndpointAddress;
    USHORT MaxPacketSize;
    BOOLEAN IsOut;
} FTD_PIPE_CANDIDATE;

static NTSTATUS
FtdGetDescriptor(
    _In_ PDEVICE_OBJECT NextLower,
    _In_ UCHAR Recipient,
    _In_ UCHAR DescType,
    _In_ USHORT Index,
    _In_ USHORT LanguageId,
    _Out_writes_bytes_(BufferLength) PVOID Buffer,
    _In_ ULONG BufferLength,
    _Out_ PULONG Transferred
    )
{
    PURB urb;
    NTSTATUS status;
    KEVENT event;
    PIRP irp;
    IO_STATUS_BLOCK iosb;
    PIO_STACK_LOCATION stack;

    *Transferred = 0;
    urb = (PURB)ExAllocatePool2(POOL_FLAG_NON_PAGED, sizeof(_URB_CONTROL_DESCRIPTOR_REQUEST), FTD_POOL_TAG);
    if (urb == NULL) {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    UsbBuildGetDescriptorRequest(
        urb,
        sizeof(_URB_CONTROL_DESCRIPTOR_REQUEST),
        DescType,
        Index,
        LanguageId,
        Buffer,
        NULL,
        BufferLength,
        NULL);

    UNREFERENCED_PARAMETER(Recipient);

    KeInitializeEvent(&event, NotificationEvent, FALSE);
    irp = IoBuildDeviceIoControlRequest(
        IOCTL_INTERNAL_USB_SUBMIT_URB,
        NextLower,
        NULL,
        0,
        NULL,
        0,
        TRUE,
        &event,
        &iosb);
    if (irp == NULL) {
        ExFreePoolWithTag(urb, FTD_POOL_TAG);
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    stack = IoGetNextIrpStackLocation(irp);
    stack->Parameters.Others.Argument1 = urb;

    status = IoCallDriver(NextLower, irp);
    if (status == STATUS_PENDING) {
        KeWaitForSingleObject(&event, Executive, KernelMode, FALSE, NULL);
        status = iosb.Status;
    }

    if (NT_SUCCESS(status)) {
        *Transferred = urb->UrbControlDescriptorRequest.TransferBufferLength;
    }

    ExFreePoolWithTag(urb, FTD_POOL_TAG);
    return status;
}

static VOID
FtdScanConfigForIsoch(
    _In_ PUSB_CONFIGURATION_DESCRIPTOR Config,
    _Out_writes_(MaxOut) FTD_PIPE_CANDIDATE *OutPipes,
    _In_ ULONG MaxOut,
    _Out_ PULONG OutCount,
    _Out_writes_(MaxIn) FTD_PIPE_CANDIDATE *InPipes,
    _In_ ULONG MaxIn,
    _Out_ PULONG InCount
    )
{
    PUCHAR start = (PUCHAR)Config;
    PUCHAR end = start + Config->wTotalLength;
    PUCHAR p = start;
    UCHAR curClass = 0;
    UCHAR curSub = 0;

    *OutCount = 0;
    *InCount = 0;

    while (p + sizeof(USB_COMMON_DESCRIPTOR) <= end) {
        PUSB_COMMON_DESCRIPTOR common = (PUSB_COMMON_DESCRIPTOR)p;
        if (common->bLength == 0) {
            break;
        }
        if (p + common->bLength > end) {
            break;
        }

        if (common->bDescriptorType == USB_INTERFACE_DESCRIPTOR_TYPE &&
            common->bLength >= sizeof(USB_INTERFACE_DESCRIPTOR)) {
            PUSB_INTERFACE_DESCRIPTOR iface = (PUSB_INTERFACE_DESCRIPTOR)p;
            curClass = iface->bInterfaceClass;
            curSub = iface->bInterfaceSubClass;
        } else if (common->bDescriptorType == USB_ENDPOINT_DESCRIPTOR_TYPE &&
                   common->bLength >= sizeof(USB_ENDPOINT_DESCRIPTOR) &&
                   curClass == USB_DEVICE_CLASS_AUDIO &&
                   curSub == FTD_UAC_SUBCLASS_AUDIOSTREAMING) {
            PUSB_ENDPOINT_DESCRIPTOR ep = (PUSB_ENDPOINT_DESCRIPTOR)p;
            UCHAR attr = ep->bmAttributes & USB_ENDPOINT_TYPE_MASK;
            if (attr == FTD_USB_ENDPOINT_TYPE_ISOCH) {
                FTD_PIPE_CANDIDATE cand;
                cand.EndpointAddress = ep->bEndpointAddress;
                cand.MaxPacketSize = ep->wMaxPacketSize;
                cand.IsOut = ((ep->bEndpointAddress & USB_ENDPOINT_DIRECTION_MASK) == 0);
                if (cand.IsOut) {
                    if (*OutCount < MaxOut) {
                        OutPipes[(*OutCount)++] = cand;
                    }
                } else {
                    if (*InCount < MaxIn) {
                        InPipes[(*InCount)++] = cand;
                    }
                }
            }
        }

        p += common->bLength;
    }
}

NTSTATUS
FtdUsbConfigure(
    _Inout_ PFTD_DEVICE_CONTEXT Ctx,
    _In_ PDEVICE_OBJECT NextLower
    )
{
    NTSTATUS status;
    USB_DEVICE_DESCRIPTOR deviceDesc;
    ULONG transferred = 0;
    ULONG configLen = 0;
    PUSB_CONFIGURATION_DESCRIPTOR config = NULL;
    FTD_PIPE_CANDIDATE outs[4];
    FTD_PIPE_CANDIDATE ins[4];
    ULONG outCount = 0;
    ULONG inCount = 0;

    Ctx->UsbConfigured = FALSE;
    Ctx->RenderPipe = NULL;
    Ctx->ConfigurationHandle = NULL;

    if (NextLower == NULL) {
        return STATUS_INVALID_PARAMETER;
    }

    status = FtdGetDescriptor(
        NextLower,
        0,
        USB_DEVICE_DESCRIPTOR_TYPE,
        0,
        0,
        &deviceDesc,
        sizeof(deviceDesc),
        &transferred);
    if (!NT_SUCCESS(status) || transferred < sizeof(USB_DEVICE_DESCRIPTOR)) {
        /*
         * Experimental path: tolerate failure so filter factories still load
         * under partial stacks. Production users should use inbox usbaudio.
         */
        return STATUS_SUCCESS;
    }

    Ctx->UsbDeviceDescriptor = deviceDesc;

    /* First pass: config header only for wTotalLength */
    {
        USB_CONFIGURATION_DESCRIPTOR header;
        status = FtdGetDescriptor(
            NextLower,
            0,
            USB_CONFIGURATION_DESCRIPTOR_TYPE,
            0,
            0,
            &header,
            sizeof(header),
            &transferred);
        if (!NT_SUCCESS(status) || transferred < sizeof(header)) {
            return STATUS_SUCCESS;
        }
        configLen = header.wTotalLength;
    }

    config = (PUSB_CONFIGURATION_DESCRIPTOR)ExAllocatePool2(
        POOL_FLAG_NON_PAGED,
        configLen,
        FTD_POOL_TAG);
    if (config == NULL) {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    status = FtdGetDescriptor(
        NextLower,
        0,
        USB_CONFIGURATION_DESCRIPTOR_TYPE,
        0,
        0,
        config,
        configLen,
        &transferred);
    if (!NT_SUCCESS(status)) {
        ExFreePoolWithTag(config, FTD_POOL_TAG);
        return STATUS_SUCCESS;
    }

    FtdScanConfigForIsoch(config, outs, 4, &outCount, ins, 4, &inCount);

    /*
     * TODO: USBD_CreateConfigurationRequestEx + SELECT_CONFIGURATION,
     * then cache USBD_PIPE_HANDLE for outs[0] / ins[0] into Ctx.
     * Until then, descriptors are parsed for bring-up diagnostics only.
     */
    UNREFERENCED_PARAMETER(outs);
    UNREFERENCED_PARAMETER(ins);
    UNREFERENCED_PARAMETER(outCount);
    UNREFERENCED_PARAMETER(inCount);

    ExFreePoolWithTag(config, FTD_POOL_TAG);
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
