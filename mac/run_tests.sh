#!/bin/zsh
# Compila ed esegue i test dell'app Mac con PowerPoint e Bluetooth finti (nessun Apple Event inviato).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 5 -target arm64-apple-macos13.0 -framework AppKit -framework PDFKit \
  Tests/main.swift Tests/ControllerTests.swift \
  Sources/Framing.swift Sources/Command.swift Sources/PairingGate.swift \
  Sources/TextCleanup.swift Sources/Messages.swift Sources/PhoneLink.swift \
  Sources/Controller.swift Sources/PowerPointBridge.swift Sources/PowerPointScript.swift \
  Sources/AppInfo.swift Sources/ThumbnailService.swift \
  -o build/tests
./build/tests "$(cd .. && pwd)"
