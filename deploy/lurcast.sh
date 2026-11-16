#!/bin/sh
# Starts Lurcast with the libraries bundled next to it, through the bundled musl loader, so the same
# build runs on any Linux, whatever its C library. The files in lib/ are ordinary shared libraries:
# you can replace one, for example with your own build of LAME (see LICENSING.md).
dir=$(dirname "$(readlink -f "$0")")
exec "$dir"/lib/ld-musl-*.so.1 --library-path "$dir/lib" --argv0 lurcast "$dir/bin/lurcast" "$@"
