#!/bin/bash
# Build Eddy.app and (with --install) copy it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Eddy.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Sources/Shaders.metal "$APP/Contents/Resources/"   # compiled at launch (see Fluid.swift)
swiftc -O Sources/*.swift -o "$APP/Contents/MacOS/Eddy"
cp Info.plist "$APP/Contents/Info.plist"

ICONSET="build/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size assets/icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) assets/icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"
# A stable signing identity keeps macOS permission grants (audio, microphone) across rebuilds;
# ad-hoc signatures change every build and reset them. Falls back to ad-hoc if the identity is absent.
IDENTITY="${CODESIGN_IDENTITY:-Pratik Dev Signing}"
security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY" || IDENTITY="-"
codesign --force -s "$IDENTITY" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p ~/Applications
    rm -rf ~/Applications/Eddy.app
    cp -R "$APP" ~/Applications/
    touch ~/Applications/Eddy.app
    echo "Installed to ~/Applications/Eddy.app"
fi
