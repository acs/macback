#!/bin/bash
# Builds a universal (Apple silicon + Intel) MacBack.app into ./build.
# Requires the Xcode command line tools only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/MacBack.app"
SDK="$(xcrun --show-sdk-path)"
DEPLOYMENT_TARGET="14.0"
ARCHS=(arm64 x86_64)

echo "==> Cleaning $APP"
rm -rf "$APP"
rm -f "$BUILD_DIR"/MacBack-*
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SLICES=()
for ARCH in "${ARCHS[@]}"; do
	SLICE="$BUILD_DIR/MacBack-$ARCH"
	echo "==> Compiling for $ARCH (macOS $DEPLOYMENT_TARGET+)"
	xcrun swiftc \
		-O \
		-swift-version 5 \
		-target "$ARCH-apple-macos$DEPLOYMENT_TARGET" \
		-sdk "$SDK" \
		-framework AppKit \
		-framework SwiftUI \
		-o "$SLICE" \
		"$ROOT"/Sources/*.swift
	SLICES+=("$SLICE")
done

echo "==> Creating universal binary"
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/MacBack"
rm -f "${SLICES[@]}"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing (ad-hoc)"
codesign --force --sign - --identifier "com.alvaro.MacBack" "$APP" >/dev/null

echo "==> Built $APP"
lipo -archs "$APP/Contents/MacOS/MacBack"
