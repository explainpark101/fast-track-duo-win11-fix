/*++
  Render filter factory descriptor (reference GUID must match INF).
--*/

#include "ftd_common.h"

extern KSPIN_DESCRIPTOR_EX FtdRenderPinDescriptorLive;
extern VOID FtdInitPinDescriptor(VOID);

static NTSTATUS
FtdRenderFilterCreate(
    _In_ PKSFILTER Filter,
    _In_ PIRP Irp
    )
{
    UNREFERENCED_PARAMETER(Filter);
    UNREFERENCED_PARAMETER(Irp);
    FtdInitPinDescriptor();
    return STATUS_SUCCESS;
}

static const KSFILTER_DISPATCH FtdRenderFilterDispatch = {
    FtdRenderFilterCreate,
    NULL, /* Close */
    NULL, /* Process */
    NULL  /* Reset */
};

static const GUID FtdRenderCategories[] = {
    STATICGUIDOF(KSCATEGORY_AUDIO),
    STATICGUIDOF(KSCATEGORY_RENDER)
};

KSFILTER_DESCRIPTOR FtdRenderFilterDescriptor = {
    &FtdRenderFilterDispatch,
    NULL, /* AutomationTable */
    KSFILTER_DESCRIPTOR_VERSION,
    0, /* Flags */
    &FTD_RENDER_FILTER_REFERENCE,
    1, /* PinDescriptorsCount */
    sizeof(KSPIN_DESCRIPTOR_EX),
    &FtdRenderPinDescriptorLive,
    SIZEOF_ARRAY(FtdRenderCategories),
    FtdRenderCategories,
    0, /* NodeDescriptorsCount */
    sizeof(KSNODE_DESCRIPTOR),
    NULL, /* NodeDescriptors */
    0, /* ConnectionsCount */
    NULL, /* Connections */
    NULL  /* ComponentId */
};
