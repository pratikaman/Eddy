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
codesign --force -s - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p ~/Applications
    rm -rf ~/Applications/Eddy.app
    cp -R "$APP" ~/Applications/
    touch ~/Applications/Eddy.app
    echo "Installed to ~/Applications/Eddy.app"
fi
