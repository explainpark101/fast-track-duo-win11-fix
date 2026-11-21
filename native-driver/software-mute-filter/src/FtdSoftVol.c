/*
 * FtdSoftVol.c — Fast Track Duo software volume / mute upper filter
 *
 * Sits above Microsoft usbaudio.sys for USB\VID_0B0F&PID_2036&MI_00.
 * Intercepts KS topology queries and removes KSNODETYPE_VOLUME /
 * KSNODETYPE_MUTE so Windows applies software mute and volume.
 *
 * Approach inspired by public WDM upper-filter patterns that hide a broken
 * hardware volume node; rewritten here for Duo with mute+volume hide and
 * connection bridging.
 */

#include "FtdSoftVol.h"

/* KSNODETYPE_VOLUME = {3A5ACC00-C557-11CE-8D04-00AA0060F5BF} */
static const GUID FtdKsNodeTypeVolume = {
    0x3A5ACC00, 0xC557, 0x11CE,
    { 0x8D, 0x04, 0x00, 0xAA, 0x00, 0x60, 0xF5, 0xBF }
};

/* KSNODETYPE_MUTE = {02B223C0-C557-11CE-8D04-00AA0060F5BF} */
static const GUID FtdKsNodeTypeMute = {
    0x02B223C0, 0xC557, 0x11CE,
    { 0x8D, 0x04, 0x00, 0xAA, 0x00, 0x60, 0xF5, 0xBF }
};

/* KSPROPSETID_Topology = {720D4AC0-7533-11D0-A5D6-28DB04C10000} */
static const GUID FtdKsPropSetTopology = {
    0x720D4AC0, 0x7533, 0x11D0,
    { 0xA5, 0xD6, 0x28, 0xDB, 0x04, 0xC1, 0x00, 0x00 }
};

static __inline BOOLEAN
FtdGuidEqual(
    _In_ const GUID *A,
    _In_ const GUID *B
    )
{
    return (BOOLEAN)RtlEqualMemory(A, B, sizeof(GUID));
}

static __inline BOOLEAN
FtdIsHiddenNode(
    _In_ PFTD_SOFTVOL_EXTENSION Ext,
    _In_ ULONG Index
    )
{
    if (Index == KSFILTER_NODE) {
        return FALSE;
    }
    if (Index >= Ext->OriginalNodeCount || Index >= FTD_SOFTVOL_MAX_NODES) {
        return FALSE;
    }
    return Ext->HideNode[Index];
}

/*
 * Map original node index -> compacted index after removals.
 * Returns KSFILTER_NODE unchanged; returns (ULONG)-2 if node was hidden.
 */
static ULONG
FtdMapNodeIndex(
    _In_ PFTD_SOFTVOL_EXTENSION Ext,
    _In_ ULONG Original
    )
{
    ULONG i;
    ULONG mapped;

    if (Original == KSFILTER_NODE) {
        return KSFILTER_NODE;
    }
    if (Original >= Ext->OriginalNodeCount) {
        return Original;
    }
    if (Original < FTD_SOFTVOL_MAX_NODES && Ext->HideNode[Original]) {
        return (ULONG)-2;
    }

    mapped = Original;
    for (i = 0; i < Original && i < FTD_SOFTVOL_MAX_NODES; i++) {
        if (Ext->HideNode[i]) {
            mapped--;
        }
    }
    return mapped;
}

NTSTATUS
DriverEntry(
    _In_ PDRIVER_OBJECT DriverObject,
    _In_ PUNICODE_STRING RegistryPath
    )
{
    ULONG i;

    UNREFERENCED_PARAMETER(RegistryPath);

    for (i = 0; i <= IRP_MJ_MAXIMUM_FUNCTION; i++) {
        DriverObject->MajorFunction[i] = FtdSoftVolPassThrough;
    }

    DriverObject->MajorFunction[IRP_MJ_DEVICE_CONTROL] = FtdSoftVolDeviceControl;
    DriverObject->MajorFunction[IRP_MJ_PNP] = FtdSoftVolPnp;
    DriverObject->MajorFunction[IRP_MJ_POWER] = FtdSoftVolPower;
    DriverObject->DriverExtension->AddDevice = FtdSoftVolAddDevice;
    DriverObject->DriverUnload = FtdSoftVolUnload;

    KdPrint(("[FtdSoftVol] DriverEntry\n"));
    return STATUS_SUCCESS;
}

NTSTATUS
FtdSoftVolAddDevice(
    _In_ PDRIVER_OBJECT DriverObject,
    _In_ PDEVICE_OBJECT PhysicalDeviceObject
    )
{
    NTSTATUS status;
    PDEVICE_OBJECT filterDevice = NULL;
    PFTD_SOFTVOL_EXTENSION ext;

    status = IoCreateDevice(
        DriverObject,
        sizeof(FTD_SOFTVOL_EXTENSION),
        NULL,
        FILE_DEVICE_UNKNOWN,
        FILE_DEVICE_SECURE_OPEN,
        FALSE,
        &filterDevice);
    if (!NT_SUCCESS(status)) {
        KdPrint(("[FtdSoftVol] IoCreateDevice 0x%08X\n", status));
        return status;
    }

    ext = (PFTD_SOFTVOL_EXTENSION)filterDevice->DeviceExtension;
    RtlZeroMemory(ext, sizeof(*ext));

    ext->NextLowerDevice = IoAttachDeviceToDeviceStack(
        filterDevice,
        PhysicalDeviceObject);
    if (ext->NextLowerDevice == NULL) {
        IoDeleteDevice(filterDevice);
        KdPrint(("[FtdSoftVol] IoAttachDeviceToDeviceStack failed\n"));
        return STATUS_UNSUCCESSFUL;
    }

    filterDevice->Flags |= (ext->NextLowerDevice->Flags &
        (DO_BUFFERED_IO | DO_DIRECT_IO | DO_POWER_PAGABLE));
    filterDevice->Flags &= ~DO_DEVICE_INITIALIZING;
    filterDevice->DeviceType = ext->NextLowerDevice->DeviceType;
    filterDevice->Characteristics = ext->NextLowerDevice->Characteristics;

    KdPrint(("[FtdSoftVol] attached\n"));
    return STATUS_SUCCESS;
}

VOID
FtdSoftVolUnload(
    _In_ PDRIVER_OBJECT DriverObject
    )
{
    UNREFERENCED_PARAMETER(DriverObject);
    KdPrint(("[FtdSoftVol] unload\n"));
}

NTSTATUS
FtdSoftVolPassThrough(
    _In_ PDEVICE_OBJECT DeviceObject,
    _Inout_ PIRP Irp
    )
{
    PFTD_SOFTVOL_EXTENSION ext =
        (PFTD_SOFTVOL_EXTENSION)DeviceObject->DeviceExtension;

    IoSkipCurrentIrpStackLocation(Irp);
    return IoCallDriver(ext->NextLowerDevice, Irp);
}

NTSTATUS
FtdSoftVolPower(
    _In_ PDEVICE_OBJECT DeviceObject,
    _Inout_ PIRP Irp
    )
{
    PFTD_SOFTVOL_EXTENSION ext =
        (PFTD_SOFTVOL_EXTENSION)DeviceObject->DeviceExtension;

    PoStartNextPowerIrp(Irp);
    IoSkipCurrentIrpStackLocation(Irp);
    return PoCallDriver(ext->NextLowerDevice, Irp);
}

NTSTATUS
FtdSoftVolPnp(
    _In_ PDEVICE_OBJECT DeviceObject,
    _Inout_ PIRP Irp
    )
{
    PFTD_SOFTVOL_EXTENSION ext =
        (PFTD_SOFTVOL_EXTENSION)DeviceObject->DeviceExtension;
    PIO_STACK_LOCATION irpSp = IoGetCurrentIrpStackLocation(Irp);
    NTSTATUS status;

    if (irpSp->MinorFunction == IRP_MN_REMOVE_DEVICE) {
        IoSkipCurrentIrpStackLocation(Irp);
        status = IoCallDriver(ext->NextLowerDevice, Irp);
        IoDetachDevice(ext->NextLowerDevice);
        IoDeleteDevice(DeviceObject);
        return status;
    }

    IoSkipCurrentIrpStackLocation(Irp);
    return IoCallDriver(ext->NextLowerDevice, Irp);
}

static BOOLEAN
FtdSafeReadKsProperty(
    _In_opt_ PVOID InputBuffer,
    _In_ ULONG InputLength,
    _Out_ KSPROPERTY *OutProp
    )
{
    if (InputBuffer == NULL || InputLength < sizeof(KSPROPERTY)) {
        return FALSE;
    }

    __try {
        ProbeForRead(InputBuffer, sizeof(KSPROPERTY), sizeof(UCHAR));
        RtlCopyMemory(OutProp, InputBuffer, sizeof(KSPROPERTY));
        return TRUE;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return FALSE;
    }
}

NTSTATUS
FtdSoftVolDeviceControl(
    _In_ PDEVICE_OBJECT DeviceObject,
    _Inout_ PIRP Irp
    )
{
    PFTD_SOFTVOL_EXTENSION ext =
        (PFTD_SOFTVOL_EXTENSION)DeviceObject->DeviceExtension;
    PIO_STACK_LOCATION irpSp = IoGetCurrentIrpStackLocation(Irp);
    ULONG ioctl = irpSp->Parameters.DeviceIoControl.IoControlCode;
    KSPROPERTY prop;

    if (ioctl != IOCTL_KS_PROPERTY) {
        goto passthrough;
    }

    if (!FtdSafeReadKsProperty(
            irpSp->Parameters.DeviceIoControl.Type3InputBuffer,
            irpSp->Parameters.DeviceIoControl.InputBufferLength,
            &prop)) {
        goto passthrough;
    }

    if (FtdGuidEqual(&prop.Set, &FtdKsPropSetTopology) &&
        prop.Id == KSPROPERTY_TOPOLOGY_NODES) {
        IoCopyCurrentIrpStackLocationToNext(Irp);
        IoSetCompletionRoutine(
            Irp,
            FtdSoftVolTopologyNodesCompletion,
            ext,
            TRUE,
            TRUE,
            TRUE);
        return IoCallDriver(ext->NextLowerDevice, Irp);
    }

    if (FtdGuidEqual(&prop.Set, &FtdKsPropSetTopology) &&
        prop.Id == KSPROPERTY_TOPOLOGY_CONNECTIONS) {
        IoCopyCurrentIrpStackLocationToNext(Irp);
        IoSetCompletionRoutine(
            Irp,
            FtdSoftVolTopologyConnectionsCompletion,
            ext,
            TRUE,
            TRUE,
            TRUE);
        return IoCallDriver(ext->NextLowerDevice, Irp);
    }

    /*
     * Do NOT reject VOLUMELEVEL/MUTE property IOCTLs. Hiding the nodes from
     * topology is enough for the Audio Engine to prefer software volume.
     * Returning STATUS_NOT_FOUND on live property traffic races multi-client
     * shared-mode graphs (Firefox silent until Chrome remounts the mix).
     */

passthrough:
    IoSkipCurrentIrpStackLocation(Irp);
    return IoCallDriver(ext->NextLowerDevice, Irp);
}

NTSTATUS
FtdSoftVolTopologyNodesCompletion(
    _In_ PDEVICE_OBJECT DeviceObject,
    _In_ PIRP Irp,
    _In_reads_opt_(_Inexpressible_("varies")) PVOID Context
    )
{
    PFTD_SOFTVOL_EXTENSION ext = (PFTD_SOFTVOL_EXTENSION)Context;
    GUID *nodes;
    ULONG count;
    ULONG i;
    ULONG dst;
    ULONG_PTR info;

    UNREFERENCED_PARAMETER(DeviceObject);

    if (!NT_SUCCESS(Irp->IoStatus.Status) || ext == NULL) {
        goto done;
    }

    info = Irp->IoStatus.Information;
    if (info < sizeof(GUID) || Irp->UserBuffer == NULL) {
        goto done;
    }

    __try {
        nodes = (GUID *)Irp->UserBuffer;
        count = (ULONG)(info / sizeof(GUID));
        if (count > FTD_SOFTVOL_MAX_NODES) {
            count = FTD_SOFTVOL_MAX_NODES;
        }

        RtlZeroMemory(ext->HideNode, sizeof(ext->HideNode));
        ext->OriginalNodeCount = count;
        ext->TopologyScanned = FALSE;

        for (i = 0; i < count; i++) {
            if (FtdGuidEqual(&nodes[i], &FtdKsNodeTypeVolume) ||
                FtdGuidEqual(&nodes[i], &FtdKsNodeTypeMute)) {
                ext->HideNode[i] = TRUE;
                KdPrint(("[FtdSoftVol] hide node %u\n", i));
            }
        }

        dst = 0;
        for (i = 0; i < count; i++) {
            if (ext->HideNode[i]) {
                continue;
            }
            if (dst != i) {
                nodes[dst] = nodes[i];
            }
            dst++;
        }

        ext->TopologyScanned = TRUE;
        Irp->IoStatus.Information = dst * sizeof(GUID);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        KdPrint(("[FtdSoftVol] exception in nodes completion\n"));
    }

done:
    if (Irp->PendingReturned) {
        IoMarkIrpPending(Irp);
    }
    return STATUS_SUCCESS;
}

/*
 * Rewrite connections: bridge across hidden nodes, drop edges that touch
 * them, then remap surviving node indices into the compacted node space.
 */
NTSTATUS
FtdSoftVolTopologyConnectionsCompletion(
    _In_ PDEVICE_OBJECT DeviceObject,
    _In_ PIRP Irp,
    _In_reads_opt_(_Inexpressible_("varies")) PVOID Context
    )
{
    PFTD_SOFTVOL_EXTENSION ext = (PFTD_SOFTVOL_EXTENSION)Context;
    KSTOPOLOGY_CONNECTION *conns;
    KSTOPOLOGY_CONNECTION *scratch = NULL;
    ULONG count;
    ULONG capacity;
    ULONG outCount;
    ULONG i;
    ULONG j;
    ULONG dst;
    ULONG_PTR info;
    ULONG pass;
    BOOLEAN changed;

    UNREFERENCED_PARAMETER(DeviceObject);

    if (!NT_SUCCESS(Irp->IoStatus.Status) ||
        ext == NULL ||
        !ext->TopologyScanned) {
        goto done;
    }

    info = Irp->IoStatus.Information;
    if (info < sizeof(KSTOPOLOGY_CONNECTION) || Irp->UserBuffer == NULL) {
        goto done;
    }

    __try {
        conns = (KSTOPOLOGY_CONNECTION *)Irp->UserBuffer;
        count = (ULONG)(info / sizeof(KSTOPOLOGY_CONNECTION));
        capacity = count * 2 + 8;

#pragma warning(suppress: 4996) /* NonPagedPoolNx preferred; WDK samples still use tag API */
        scratch = (KSTOPOLOGY_CONNECTION *)ExAllocatePoolWithTag(
            NonPagedPoolNx,
            capacity * sizeof(KSTOPOLOGY_CONNECTION),
            FTD_SOFTVOL_TAG);

        if (scratch != NULL) {
            RtlCopyMemory(
                scratch,
                conns,
                count * sizeof(KSTOPOLOGY_CONNECTION));
            outCount = count;

            /*
             * Bridge: for A -> H (-> ... ->) B where H is hidden, emit A -> B.
             * Iterate until stable (handles VOLUME then MUTE chains).
             */
            for (pass = 0; pass < FTD_SOFTVOL_MAX_NODES; pass++) {
                changed = FALSE;
                for (i = 0; i < outCount; i++) {
                    ULONG to = scratch[i].ToNode;
                    if (!FtdIsHiddenNode(ext, to)) {
                        continue;
                    }
                    for (j = 0; j < outCount; j++) {
                        if (scratch[j].FromNode != to) {
                            continue;
                        }
                        if (outCount >= capacity) {
                            break;
                        }
                        scratch[outCount] = scratch[i];
                        scratch[outCount].ToNode = scratch[j].ToNode;
                        scratch[outCount].ToNodePin = scratch[j].ToNodePin;
                        outCount++;
                        changed = TRUE;
                    }
                }
                if (!changed) {
                    break;
                }
            }

            dst = 0;
            for (i = 0; i < outCount; i++) {
                ULONG fromMapped;
                ULONG toMapped;

                if (FtdIsHiddenNode(ext, scratch[i].FromNode) ||
                    FtdIsHiddenNode(ext, scratch[i].ToNode)) {
                    continue;
                }

                fromMapped = FtdMapNodeIndex(ext, scratch[i].FromNode);
                toMapped = FtdMapNodeIndex(ext, scratch[i].ToNode);
                if (fromMapped == (ULONG)-2 || toMapped == (ULONG)-2) {
                    continue;
                }

                /* UserBuffer is only sized for the original connection list. */
                if (dst >= count) {
                    break;
                }
                conns[dst] = scratch[i];
                conns[dst].FromNode = fromMapped;
                conns[dst].ToNode = toMapped;
                dst++;
            }

            ExFreePoolWithTag(scratch, FTD_SOFTVOL_TAG);
            scratch = NULL;
        } else {
            /* No pool: drop edges that touch hidden nodes (no bridge). */
            dst = 0;
            for (i = 0; i < count; i++) {
                ULONG fromMapped;
                ULONG toMapped;

                if (FtdIsHiddenNode(ext, conns[i].FromNode) ||
                    FtdIsHiddenNode(ext, conns[i].ToNode)) {
                    continue;
                }
                fromMapped = FtdMapNodeIndex(ext, conns[i].FromNode);
                toMapped = FtdMapNodeIndex(ext, conns[i].ToNode);
                if (fromMapped == (ULONG)-2 || toMapped == (ULONG)-2) {
                    continue;
                }
                conns[dst] = conns[i];
                conns[dst].FromNode = fromMapped;
                conns[dst].ToNode = toMapped;
                dst++;
            }
        }

        Irp->IoStatus.Information = dst * sizeof(KSTOPOLOGY_CONNECTION);
        KdPrint(("[FtdSoftVol] connections %u -> %u\n", count, dst));
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        KdPrint(("[FtdSoftVol] exception in connections completion\n"));
        if (scratch != NULL) {
            ExFreePoolWithTag(scratch, FTD_SOFTVOL_TAG);
        }
    }

done:
    if (Irp->PendingReturned) {
        IoMarkIrpPending(Irp);
    }
    return STATUS_SUCCESS;
}
