#!/bin/zsh
# Compila ed esegue i test delle parti "pure" dell'app Mac (niente Bluetooth né PowerPoint).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 5 -target arm64-apple-macos13.0 \
  Tests/main.swift \
  Sources/Framing.swift Sources/Command.swift Sources/PairingGate.swift \
  Sources/TextCleanup.swift Sources/Messages.swift \
  -o build/tests
./build/tests "$(cd .. && pwd)"
