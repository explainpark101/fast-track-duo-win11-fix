/*++
  Stream lifetime gate — primary defense against the legacy Duo UAF class of bug.

  Legacy AvidFastTrackDuo.sys faulted at +0x1849d reading PCM at DISPATCH_LEVEL
  after WASAPI teardown freed/paged the buffer. This gate ensures Process never
  touches stream memory once stop has begun, and stop waits for in-flight work.
--*/

#include "ftd_common.h"

VOID
FtdGateInit(
    _Out_ PFTD_STREAM_GATE Gate
    )
{
    RtlZeroMemory(Gate, sizeof(*Gate));
    KeInitializeEvent(&Gate->DrainEvent, NotificationEvent, TRUE);
    Gate->Running = 0;
    Gate->Generation = 1;
    Gate->InFlight = 0;
}

VOID
FtdGateAllowRun(
    _Inout_ PFTD_STREAM_GATE Gate
    )
{
    InterlockedExchange(&Gate->Running, 1);
    KeClearEvent(&Gate->DrainEvent);
}

VOID
FtdGateStopAndDrain(
    _Inout_ PFTD_STREAM_GATE Gate
    )
{
    InterlockedExchange(&Gate->Running, 0);
    InterlockedIncrement(&Gate->Generation);

    /*
     * PASSIVE_LEVEL expected for SetState(STOP). Spin briefly then wait so any
     * DPC/process path that already passed TryEnter can finish without touching
     * freed MDLs afterward.
     */
    while (InterlockedCompareExchange(&Gate->InFlight, 0, 0) != 0) {
        LARGE_INTEGER interval;
        interval.QuadPart = -10 * 1000 * 10; /* 10 ms */
        KeWaitForSingleObject(
            &Gate->DrainEvent,
            Executive,
            KernelMode,
            FALSE,
            &interval);
    }

    KeSetEvent(&Gate->DrainEvent, IO_NO_INCREMENT, FALSE);
}

BOOLEAN
FtdGateTryEnter(
    _Inout_ PFTD_STREAM_GATE Gate,
    _Out_ LONG *Cookie
    )
{
    LONG gen;

    if (InterlockedCompareExchange(&Gate->Running, 1, 1) != 1) {
        return FALSE;
    }

    gen = InterlockedCompareExchange(&Gate->Generation, 0, 0);
    InterlockedIncrement(&Gate->InFlight);

    if (InterlockedCompareExchange(&Gate->Running, 1, 1) != 1 ||
        InterlockedCompareExchange(&Gate->Generation, 0, 0) != gen) {
        if (InterlockedDecrement(&Gate->InFlight) == 0) {
            KeSetEvent(&Gate->DrainEvent, IO_NO_INCREMENT, FALSE);
        }
        return FALSE;
    }

    *Cookie = gen;
    return TRUE;
}

VOID
FtdGateLeave(
    _Inout_ PFTD_STREAM_GATE Gate,
    _In_ LONG Cookie
    )
{
    UNREFERENCED_PARAMETER(Cookie);

    if (InterlockedDecrement(&Gate->InFlight) == 0) {
        KeSetEvent(&Gate->DrainEvent, IO_NO_INCREMENT, FALSE);
    }
}
