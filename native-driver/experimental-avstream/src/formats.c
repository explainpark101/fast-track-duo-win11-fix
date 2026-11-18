/*++
  Provisional PCM ranges. Replace with values parsed from Duo CS descriptors.
--*/

#include "ftd_common.h"

static const KSDATARANGE_AUDIO PinDataRangesRenderStream[] = {
    {
        {
            sizeof(KSDATARANGE_AUDIO),
            0,
            0,
            0,
            STATICGUIDOF(KSDATAFORMAT_TYPE_AUDIO),
            STATICGUIDOF(KSDATAFORMAT_SUBTYPE_PCM),
            STATICGUIDOF(KSDATAFORMAT_SPECIFIER_WAVEFORMATEX)
        },
        2,      /* MaximumChannels */
        16,     /* MinimumBitsPerSample */
        16,     /* MaximumBitsPerSample */
        44100,  /* MinimumSampleFrequency */
        48000   /* MaximumSampleFrequency */
    }
};

static const PKSDATARANGE PinDataRangePointersRenderStream[] = {
    (PKSDATARANGE)&PinDataRangesRenderStream[0]
};

const PKSDATARANGE* FtdRenderPinDataRanges = PinDataRangePointersRenderStream;
const ULONG FtdRenderPinDataRangeCount = SIZEOF_ARRAY(PinDataRangePointersRenderStream);
