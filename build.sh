#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
ARCH="$(uname -m)"
SDK="$(xcrun --show-sdk-path)"
SWIFT_VERSION="$(swiftc --version)"
if [[ "$SWIFT_VERSION" == *"Swift version 6.1"* ]] && [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk ]; then
  SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk
fi
BUILD_TEMP="$(mktemp -d)"
trap 'rm -rf "$BUILD_TEMP"' EXIT
APP="dist/作品集压缩器.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -swift-version 5 -sdk "$SDK" -target "$ARCH-apple-macosx14.0" -O -module-cache-path "$BUILD_TEMP/cache" Source/Engine.swift Source/App.swift -o "$BUILD_TEMP/PortfolioPress"
cp "$BUILD_TEMP/PortfolioPress" "$APP/Contents/MacOS/PortfolioPress"
cp Assets/Info.plist "$APP/Contents/Info.plist"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
VERSION="$(plutil -extract CFBundleShortVersionString raw Assets/Info.plist)"
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/PortfolioPress-$VERSION-$ARCH.zip"
echo "Built $APP ($ARCH)"
