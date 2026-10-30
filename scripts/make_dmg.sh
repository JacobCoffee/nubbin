#!/bin/sh
# Package an app bundle as a drag-to-install disk image.
# usage: scripts/make_dmg.sh build/Nubbin.app build/Nubbin.dmg
set -eu

app=$1
dmg=$2
name=$(basename "$app" .app)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

ditto "$app" "$stage/$name.app"
ln -s /Applications "$stage/Applications"
rm -f "$dmg"
hdiutil create -volname "$name" -srcfolder "$stage" -fs HFS+ -format UDZO -imagekey zlib-level=9 -quiet "$dmg"
