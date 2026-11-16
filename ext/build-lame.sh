#!/bin/sh
# Builds and installs LAME (libmp3lame, LGPL 2 or later) as a shared library for the release build,
# which bundles it as a separate, replaceable file. Only the encoder library: no decoder, no
# command-line tool. The release tarball is checked against its SHA-256; with LURCAST_SOURCES set,
# it is also copied there, to publish with the release.
# Usage: sh ext/build-lame.sh [prefix]   (default prefix: /usr)
set -eu

version=4.0
sha256=3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb
prefix=${1:-/usr}
tarball="lame-$version.tar.gz"
url="https://downloads.sourceforge.net/project/lame/lame/$version/$tarball"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL -o "$tarball" "$url"
else
  wget -q -O "$tarball" "$url"
fi
echo "$sha256  $tarball" | sha256sum -c -
if [ -n "${LURCAST_SOURCES:-}" ]; then mkdir -p "$LURCAST_SOURCES" && cp "$tarball" "$LURCAST_SOURCES/"; fi
tar xzf "$tarball"
cd "lame-$version"
./configure --prefix="$prefix" --enable-shared --disable-static \
  --disable-frontend --disable-decoder --disable-analyzer-hooks --disable-gtktest >/dev/null
make -j"$(nproc 2>/dev/null || echo 2)" >/dev/null
make install >/dev/null
