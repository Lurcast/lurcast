#!/bin/sh
# Compiles the vendored C code in this directory into one static archive and prints its path.
# The transcode plugin runs this from a macro while Crystal compiles, and links the archive.
# Archives are cached by a checksum of the sources, compiler and flags, so this only compiles
# when something changed. Set LURCAST_EXT_CACHE to choose the cache directory.
set -eu

ext_dir=$(cd "$(dirname "$0")" && pwd)
cc=${CC:-cc}
ar=${AR:-ar}
cflags="-O2 -fPIC -w"
sources="lurcast_minimp3.c lurcast_stb_vorbis.c lurcast_resample.c"

key=$(
  cd "$ext_dir"
  {
    echo "$cc $cflags $sources"
    "$cc" --version 2>/dev/null | head -n 1
    uname -sm
    cat build.sh $sources minimp3/minimp3.h stb_vorbis/stb_vorbis.c speexdsp/*.c speexdsp/*.h
  } | cksum | tr -d ' \t'
)

cache_root=${LURCAST_EXT_CACHE:-${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/lurcast-ext}
if ! mkdir -p "$cache_root" 2>/dev/null || [ ! -w "$cache_root" ]; then
  cache_root=${TMPDIR:-/tmp}/lurcast-ext-$(id -u)
  mkdir -p "$cache_root"
fi
archive="$cache_root/liblurcast_ext-$key.a"

if [ ! -f "$archive" ]; then
  work=$(mktemp -d "$cache_root/build.XXXXXX")
  trap 'rm -rf "$work"' EXIT
  for source in $sources; do
    "$cc" $cflags -I"$ext_dir" -c "$ext_dir/$source" -o "$work/${source%.c}.o" >&2
  done
  "$ar" rcs "$work/liblurcast_ext.a" "$work"/*.o >&2
  # Rename into place so builds running at the same time never link a half-written archive.
  mv -f "$work/liblurcast_ext.a" "$archive"
fi

printf '%s' "$archive"
