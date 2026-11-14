#!/bin/bash
# Builds TakeoutHub.app with the Command Line Tools only, without Xcode or a developer certificate.
#
#   ./build.sh            → build/TakeoutHub.app
#   ./build.sh --install  → also copies it to /Applications/StudioHub
#   ./build.sh --icon     → redraws the app icon (Resources/AppIcon.icns)
set -euo pipefail
cd "$(dirname "$0")"

APP="build/TakeoutHub.app"
INSTALL_DIR="/Applications/StudioHub"
mkdir -p build

# Installing replaces the app, so it must not be running.
if [[ "${1:-}" == "--install" ]] && pgrep -f "TakeoutHub.app/Contents/MacOS/TakeoutHub" >/dev/null; then
  echo "TakeoutHub läuft. Bitte beenden und dann erneut installieren." >&2
  exit 1
fi

FLAGS=(-O -swift-version 5 -target "$(uname -m)-apple-macos14.0")

# Some Command Line Tools installs ship an outdated module.modulemap that clashes with
# bridging.modulemap ("redefinition of module 'SwiftBridging'"). A VFS overlay hides it while
# compiling; the system itself stays unchanged.
SWIFT_INCLUDE="$(dirname "$(dirname "$(xcrun -f swiftc)")")/include/swift"
if [[ -f "$SWIFT_INCLUDE/module.modulemap" && -f "$SWIFT_INCLUDE/bridging.modulemap" ]]; then
  : > build/empty.modulemap
  cat > build/clt-overlay.yaml <<EOF
{ "version": 0, "case-sensitive": "false", "roots": [ { "name": "$SWIFT_INCLUDE", "type": "directory",
  "contents": [ { "name": "module.modulemap", "type": "file", "external-contents": "$PWD/build/empty.modulemap" } ] } ] }
EOF
  FLAGS+=(-vfsoverlay build/clt-overlay.yaml -Xcc -ivfsoverlay -Xcc build/clt-overlay.yaml)
fi

if [[ "${1:-}" == "--icon" ]]; then
  swiftc "${FLAGS[@]}" -o build/make-icon scripts/make-icon.swift
  rm -rf build/AppIcon.iconset
  build/make-icon build/AppIcon.iconset
  mkdir -p Resources
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
  echo "Icon aktualisiert: Resources/AppIcon.icns"
  exit 0
fi

echo "Kompiliere …"
swiftc "${FLAGS[@]}" -parse-as-library -module-name TakeoutHub -o build/TakeoutHub Sources/TakeoutHub/*.swift

echo "Erstelle $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/TakeoutHub "$APP/Contents/MacOS/TakeoutHub"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature ("-") with Hardened Runtime: needs neither a certificate nor an Apple account, but
# prevents injecting foreign libraries into the running app.
codesign --force --options runtime --sign - "$APP"
codesign --verify --strict "$APP"
[[ "$(codesign -dv "$APP" 2>&1)" == *"flags="*"runtime"* ]] || { echo "Hardened Runtime fehlt in der Signatur." >&2; exit 1; }

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALL_DIR/TakeoutHub.app"
  cp -R "$APP" "$INSTALL_DIR/"
  echo "Installiert: $INSTALL_DIR/TakeoutHub.app"
fi

echo "Fertig: $APP"
