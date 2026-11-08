#!/bin/zsh
set -euo pipefail

cd -- "${0:A:h}"
if (( $# > 1 )) || [[ "${1:-}" != "" && "$1" != "--run" ]]; then
    print -u2 "Usage: ./build.sh [--run]"
    exit 2
fi

app="build/DeskRename.app"
stage="$(mktemp -d "$PWD/build-stage.XXXXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
mkdir -p "$stage/DeskRename.app/Contents/MacOS" build/.swift-cache
arch="$(uname -m)"
xcrun swiftc -O -whole-module-optimization -warnings-as-errors \
    -target "${arch}-apple-macosx26.0" \
    -module-cache-path "$PWD/build/.swift-cache" \
    Sources/*.swift -o "$stage/DeskRename.app/Contents/MacOS/DeskRename"
cp Info.plist "$stage/DeskRename.app/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$stage/DeskRename.app"
/usr/bin/codesign --verify --strict "$stage/DeskRename.app"
/usr/bin/ditto "$stage/DeskRename.app" "$app"
print -- "$PWD/$app"

if [[ "${1:-}" == "--run" ]]; then
    /usr/bin/open "$app"
fi
