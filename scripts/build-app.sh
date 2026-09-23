#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
configuration="${1:-release}"
if pgrep -x Ara >/dev/null; then
    printf 'Quit Ara before rebuilding its app bundle.\n' >&2
    exit 1
fi
swift build --configuration "$configuration" --arch arm64 --product Ara
binary_dir="$(swift build --configuration "$configuration" --arch arm64 --show-bin-path)"
app="build/Ara.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/Ara" "$app/Contents/MacOS/Ara"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/Ara.icns "$app/Contents/Resources/Ara.icns"
codesign --force --sign - "$app"
printf 'Built %s\n' "$PWD/$app"
