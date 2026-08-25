#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
NATIVE_DIR="$BUILD_DIR/native"
APP_DIR="$BUILD_DIR/BabelWave.app"
SWIFT_MODULE_CACHE="$BUILD_DIR/swift-module-cache"
SWIFT_SDK="$(xcrun --sdk macosx15.4 --show-sdk-path)"

cmake -S "$PROJECT_DIR" -B "$NATIVE_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
BUILD_JOBS="${BABELWAVE_BUILD_JOBS:-8}"
cmake --build "$NATIVE_DIR" --target babelwaved --parallel "$BUILD_JOBS"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" \
         "$APP_DIR/Contents/Resources/bin" \
         "$APP_DIR/Contents/Frameworks"

swiftc -parse-as-library -swift-version 5 -O \
    -target arm64-apple-macos14.0 \
    -sdk "$SWIFT_SDK" \
    -module-cache-path "$SWIFT_MODULE_CACHE" \
    "$PROJECT_DIR"/Sources/App/*.swift \
    -o "$APP_DIR/Contents/MacOS/BabelWave"

cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/Resources/BabelWaveLogo.png" "$APP_DIR/Contents/Resources/BabelWaveLogo.png"
cp "$PROJECT_DIR/Resources/MenuBarIconTemplate.pdf" \
    "$APP_DIR/Contents/Resources/MenuBarIconTemplate.pdf"
cp "$NATIVE_DIR/babelwaved" "$APP_DIR/Contents/Resources/bin/babelwaved"
find "$NATIVE_DIR" -maxdepth 3 -name '*.dylib' -exec cp -a {} "$APP_DIR/Contents/Frameworks/" \;

install_name_tool -add_rpath '@executable_path/../../Frameworks' \
    "$APP_DIR/Contents/Resources/bin/babelwaved" 2>/dev/null || true

codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
