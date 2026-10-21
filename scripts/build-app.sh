#!/bin/zsh
# Compila Holgura en Release con xcodebuild y empaqueta dist/Holgura.app (firma ad-hoc, sin sandbox).
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

DERIVED="$ROOT/build/DerivedData"
APP="$ROOT/dist/Holgura.app"

echo "▸ Compilando (Release)…"
xcodebuild -scheme Holgura -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" build -quiet

BIN="$DERIVED/Build/Products/Release/Holgura"
[[ -x "$BIN" ]] || { echo "No se encontró el ejecutable en $BIN"; exit 1; }

echo "▸ Generando ícono…"
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"
swift "$ROOT/scripts/make-icon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$ROOT/build/AppIcon.icns"

echo "▸ Empaquetando $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Holgura"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Firmando (ad-hoc)…"
codesign --force --sign - --entitlements "$ROOT/Resources/Holgura.entitlements" "$APP"
codesign --verify --verbose=1 "$APP"

echo "✓ Listo: $APP"
