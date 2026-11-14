#!/bin/sh
# Builds and installs libopus as a static library, for the static (musl) release build: Alpine
# packages libopus only as a shared library. The release tarball is checked against its SHA-256.
# Usage: sh ext/build-static-opus.sh [prefix]   (default prefix: /usr)
set -eu

version=1.6.1
sha256=6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
prefix=${1:-/usr}
tarball="opus-$version.tar.gz"
url="https://downloads.xiph.org/releases/opus/$tarball"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL -o "$tarball" "$url"
else
  wget -q -O "$tarball" "$url"
fi
echo "$sha256  $tarball" | sha256sum -c -
tar xzf "$tarball"
cd "opus-$version"
./configure --prefix="$prefix" --enable-static --disable-shared --with-pic \
  --disable-doc --disable-extra-programs >/dev/null
make -j"$(nproc 2>/dev/null || echo 2)" >/dev/null
make install >/dev/null
