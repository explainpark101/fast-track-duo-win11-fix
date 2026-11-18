/*++
  FastTrackDuoNew DriverEntry — hand off to AVStream.
--*/

#include <initguid.h>
#include "ftd_common.h"

extern VOID FtdInitPinDescriptor(VOID);

DRIVER_INITIALIZE DriverEntry;

NTSTATUS
DriverEntry(
    _In_ PDRIVER_OBJECT DriverObject,
    _In_ PUNICODE_STRING RegistryPath
    )
{
    FtdInitPinDescriptor();
    return KsInitializeDriver(
        DriverObject,
        RegistryPath,
        &FtdDeviceDescriptor);
}
