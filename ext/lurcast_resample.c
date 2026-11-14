/* Builds the vendored Speex resampler (BSD) on its own, in floating point, with lurcast_ symbol
   names (lurcast_resampler_init, ...), for the transcode plugin. */
#define OUTSIDE_SPEEX
#define FLOATING_POINT
#define RANDOM_PREFIX lurcast
#define EXPORT
#include "speexdsp/resample.c"
