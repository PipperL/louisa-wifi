#!/bin/bash
# Build build/LouisaWiFi.app (and a zip for GitHub Releases).
# Needs only the Xcode Command Line Tools: xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

ARCHS=${ARCHS:-"arm64 x86_64"}
APP=build/LouisaWiFi.app

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

bins=()
for arch in $ARCHS; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13" app/Sources/*.swift -o "build/LouisaWiFi-$arch"
  bins+=("build/LouisaWiFi-$arch")
done
lipo -create "${bins[@]}" -output "$APP/Contents/MacOS/LouisaWiFi"
rm "${bins[@]}"

cp app/Info.plist "$APP/Contents/"
# Release builds pass VERSION=1.2.3 (from the git tag).
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
cp data/stores.json "$APP/Contents/Resources/"
[ -f data/stores.meta.json ] && cp data/stores.meta.json "$APP/Contents/Resources/"
# The commit this build came from, shown in the menu.
if [ -n "${COMMIT:-}" ]; then
  /usr/libexec/PlistBuddy -c "Add :LouisaGitCommit string $COMMIT" "$APP/Contents/Info.plist"
fi

# App icon: app/AppIcon.png (1024×1024) → AppIcon.icns
ICONSET=build/AppIcon.iconset
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size app/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) app/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"
codesign --force --sign - "$APP"

ditto -c -k --keepParent "$APP" build/LouisaWiFi.zip
echo "Built $APP"
