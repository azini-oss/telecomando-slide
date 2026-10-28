#!/bin/zsh
# Compila "Telecomando Slide.app" (arm64 nativo), la firma con runtime rinforzato e la installa in ~/Applications.
# Niente download, niente script dentro l'app: solo il binario Swift compilato qui.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Telecomando Slide"
BUNDLE_ID="com.azini.telecomandoslide"
BUILD="build"
APP="$BUILD/$APP_NAME.app"
DEST="$HOME/Applications/$APP_NAME.app"

./run_tests.sh

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -framework AppKit -framework CoreBluetooth -framework CoreImage \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/TelecomandoSlide"

cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Firma ad-hoc (nessun certificato Apple disponibile) con runtime rinforzato e un solo entitlement.
codesign --force --options runtime --timestamp=none \
  --entitlements Resources/TelecomandoSlide.entitlements \
  --identifier "$BUNDLE_ID" --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$APP" "$DEST"
codesign --verify --strict "$DEST"
echo "Installata: $DEST"
