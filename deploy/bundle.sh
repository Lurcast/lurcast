#!/bin/sh
# Collects a dynamically linked Lurcast build (made on Alpine) into a folder that runs on any Linux:
# the binary in bin/, every shared library it loads and musl's dynamic loader in lib/, the start
# script, and the license files. Run it where the build was made, so ldd finds the same libraries.
# Usage: sh deploy/bundle.sh bin/lurcast dist/lurcast
set -eu

binary=$1
out=$2
root=$(cd "$(dirname "$0")/.." && pwd)

rm -rf "$out"
mkdir -p "$out/bin" "$out/lib"
cp "$binary" "$out/bin/lurcast"
chmod 0755 "$out/bin/lurcast"

# ldd lists the loader by its path ("/lib/ld-musl-x86_64.so.1 (0x...)"), and each library as
# "name => path (0x...)". musl's libc is the loader itself, so its "libc.musl-*" entry is skipped.
ldd "$binary" | while read -r first second third _; do
  case "$first" in
    /*) cp -L "$first" "$out/lib/$(basename "$first")" ;;
    libc.musl-*) ;;
    *) if [ "$second" = "=>" ]; then cp -L "$third" "$out/lib/$first"; fi ;;
  esac
done
ls "$out"/lib/ld-musl-*.so.1 >/dev/null

cp "$root/deploy/lurcast.sh" "$out/lurcast"
chmod 0755 "$out/lurcast"
cp "$root/LICENSE" "$root/LICENSING.md" "$root/THIRD_PARTY_NOTICES.txt" "$out/"
