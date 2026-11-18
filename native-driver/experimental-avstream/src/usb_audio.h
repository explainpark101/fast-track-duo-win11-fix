/*++
  USB Audio class bring-up stubs (next milestone).
--*/

#pragma once

#include "ftd_common.h"

/* Placeholder CS descriptor offsets — fill after dumping Duo config on device. */
NTSTATUS
FtdUsbConfigure(
    _Inout_ PFTD_DEVICE_CONTEXT Ctx,
    _In_ PDEVICE_OBJECT NextLower
    );

VOID
FtdUsbRelease(
    _Inout_ PFTD_DEVICE_CONTEXT Ctx
    );
