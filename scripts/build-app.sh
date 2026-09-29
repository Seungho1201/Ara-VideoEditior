#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
configuration="${1:-release}"
if pgrep -x Ara >/dev/null; then
    printf 'Quit Ara before rebuilding its app bundle.\n' >&2
    exit 1
fi
# Linked against the current SDK; the deployment target stays macOS 15. swiftc hands the SDK to
# the linker only as --sysroot, which does not give its version (-isysroot does): the app would be
# marked as built with the macOS 15 SDK, and AppKit and SwiftUI would draw it in their older design.
sdk="$(xcrun --sdk macosx --show-sdk-path)"
swift build --configuration "$configuration" --arch arm64 --product Ara -Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$sdk"
binary_dir="$(swift build --configuration "$configuration" --arch arm64 --show-bin-path)"
app="build/Ara.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/Ara" "$app/Contents/MacOS/Ara"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/Ara.icns "$app/Contents/Resources/Ara.icns"
# The interface's translations (the language is chosen in Settings).
for lproj in Resources/*.lproj; do
    rm -rf "$app/Contents/Resources/$(basename "$lproj")"
    cp -R "$lproj" "$app/Contents/Resources/"
done
codesign --force --sign - "$app"
printf 'Built %s\n' "$PWD/$app"
