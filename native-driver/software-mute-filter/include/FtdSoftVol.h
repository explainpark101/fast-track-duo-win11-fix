/*
 * FtdSoftVol.h — Fast Track Duo software volume / mute upper filter
 *
 * WDM upper filter above usbaudio.sys. Hides KSNODETYPE_VOLUME and
 * KSNODETYPE_MUTE so the Windows Audio Engine uses software volume/mute
 * instead of a no-op (or analog-only) USB Feature Unit path.
 */

#pragma once

#include <ntddk.h>

#ifndef FILE_DEVICE_KS
#define FILE_DEVICE_KS 0x0000002F
#endif

#define IOCTL_KS_PROPERTY CTL_CODE(FILE_DEVICE_KS, 0x000, METHOD_NEITHER, FILE_ANY_ACCESS)

typedef struct {
    GUID Set;
    ULONG Id;
    ULONG Flags;
} KSPROPERTY;

typedef struct {
    ULONG FromNode;
    ULONG FromNodePin;
    ULONG ToNode;
    ULONG ToNodePin;
} KSTOPOLOGY_CONNECTION;

#define KSFILTER_NODE ((ULONG)-1)

#define KSPROPERTY_TOPOLOGY_NODES       1
#define KSPROPERTY_TOPOLOGY_CONNECTIONS 2

#define KSPROPERTY_AUDIO_VOLUMELEVEL 4
#define KSPROPERTY_AUDIO_MUTE        13

#define FTD_SOFTVOL_TAG 'voSF'
#define FTD_SOFTVOL_MAX_NODES 64

typedef struct _FTD_SOFTVOL_EXTENSION {
    PDEVICE_OBJECT NextLowerDevice;
    /* Original node indices that were hidden (pre-compaction). */
    BOOLEAN HideNode[FTD_SOFTVOL_MAX_NODES];
    ULONG OriginalNodeCount;
    BOOLEAN TopologyScanned;
} FTD_SOFTVOL_EXTENSION, *PFTD_SOFTVOL_EXTENSION;

DRIVER_INITIALIZE DriverEntry;
DRIVER_ADD_DEVICE FtdSoftVolAddDevice;
DRIVER_UNLOAD FtdSoftVolUnload;

DRIVER_DISPATCH FtdSoftVolPassThrough;
DRIVER_DISPATCH FtdSoftVolDeviceControl;
DRIVER_DISPATCH FtdSoftVolPnp;
DRIVER_DISPATCH FtdSoftVolPower;

IO_COMPLETION_ROUTINE FtdSoftVolTopologyNodesCompletion;
IO_COMPLETION_ROUTINE FtdSoftVolTopologyConnectionsCompletion;
