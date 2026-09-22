#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/KVMLink.app"
STAGE_DIR="$(mktemp -d)"
STAGED_APP="$STAGE_DIR/KVMLink.app"
OBJECT_DIR="$STAGE_DIR/Objects"
M1DDC_DIR="$ROOT_DIR/Vendor/m1ddc"
trap 'rm -rf -- "$STAGE_DIR"' EXIT

mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources" "$OBJECT_DIR" "$BUILD_DIR"

xcrun clang -c -O2 -fmodules \
  -I "$M1DDC_DIR/headers" \
  "$M1DDC_DIR/sources/i2c.m" \
  -o "$OBJECT_DIR/i2c.o"

xcrun clang -c -O2 -fmodules \
  -I "$M1DDC_DIR/headers" \
  "$M1DDC_DIR/sources/ioregistry.m" \
  -o "$OBJECT_DIR/ioregistry.o"

xcrun clang -c -O2 -fmodules \
  -I "$M1DDC_DIR/headers" \
  "$ROOT_DIR/Sources/DDCBridge.m" \
  -o "$OBJECT_DIR/DDCBridge.o"

xcrun swiftc \
  -swift-version 5 \
  -O \
  -framework AppKit \
  -framework CoreGraphics \
  -framework CoreDisplay \
  -framework Foundation \
  -framework IOKit \
  -framework ServiceManagement \
  "$ROOT_DIR/Sources/main.swift" \
  "$OBJECT_DIR/i2c.o" \
  "$OBJECT_DIR/ioregistry.o" \
  "$OBJECT_DIR/DDCBridge.o" \
  -o "$STAGED_APP/Contents/MacOS/USBDisplayLink"

cp "$ROOT_DIR/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$ROOT_DIR/README.md" "$STAGED_APP/Contents/Resources/README.md"
cp "$ROOT_DIR/THIRD-PARTY-NOTICES.md" "$STAGED_APP/Contents/Resources/THIRD-PARTY-NOTICES.md"
xattr -cr "$STAGED_APP"
codesign --force --deep --sign - "$STAGED_APP"

if [[ "$APP_DIR" == "$ROOT_DIR/build/KVMLink.app" ]]; then
  rm -rf -- "$APP_DIR"
fi
ditto "$STAGED_APP" "$APP_DIR"

print -r -- "$APP_DIR"
