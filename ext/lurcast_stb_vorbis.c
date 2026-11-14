/* Builds the vendored stb_vorbis decoder (public domain or MIT) with only its push API, for the
   transcode plugin. */
#define STB_VORBIS_NO_STDIO
#define STB_VORBIS_NO_PULLDATA_API
#define STB_VORBIS_NO_INTEGER_CONVERSION
#include "stb_vorbis/stb_vorbis.c"
