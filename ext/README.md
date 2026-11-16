# Vendored C code

Third-party C code compiled into Lurcast by the transcode plugin (`src/plugins/transcode/`). The
files are unmodified copies of the upstream files and keep their license headers. All of them are
under permissive licenses, so they can be linked into the open-source and commercially licensed
builds alike. LAME (LGPL) is not vendored; see below.

| File | Upstream | Version | License |
|---|---|---|---|
| `minimp3/minimp3.h`, `minimp3/LICENSE` | [lieff/minimp3](https://github.com/lieff/minimp3) | commit `ea99364f61c14656440e8d77e9c233ccf3124633` | CC0 1.0 |
| `stb_vorbis/stb_vorbis.c` | [nothings/stb](https://github.com/nothings/stb) | v1.24, commit `9600522de53973336fa033a289858a4354cbb04c` | MIT or public domain (Unlicense), at your choice |
| `speexdsp/resample.c`, `speexdsp/speex_resampler.h`, `speexdsp/arch.h`, `speexdsp/COPYING` | [xiph/speexdsp](https://github.com/xiph/speexdsp) | SpeexDSP-1.2.1, commit `1b28a0f61bc31162979e1f26f3981fc3637095c8` | BSD 3-clause |

Lurcast's own files here:

- `lurcast_minimp3.c`, `lurcast_stb_vorbis.c`, `lurcast_resample.c` build each library with the
  options Lurcast uses (float output, push API only, the Speex resampler outside Speex with
  `lurcast_` symbol names).
- `build.sh` compiles them into `liblurcast_ext-<checksum>.a` in a cache directory
  (`$LURCAST_EXT_CACHE`, else `$XDG_CACHE_HOME/lurcast-ext` or `~/.cache/lurcast-ext`) and prints
  its path. `src/plugins/transcode/native.cr` runs it while Crystal compiles, so `crystal build`
  and `crystal spec` need a C compiler (`$CC`, default `cc`) and `ar`; it only recompiles when a
  source, the compiler or the flags change.
- `build-lame.sh` builds LAME 4.0 (LGPL 2 or later, encoder library only) as a shared library for
  the release build, checked against its SHA-256. With `LURCAST_SOURCES` set, it also copies the
  source tarball there, to attach to the release.

libopus and LAME are not vendored: they are linked from the system (`pkg-config opus` and `lame`;
Homebrew `opus lame`, Debian and Ubuntu `libopus-dev libmp3lame-dev`).
