#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
SDK="$(xcrun --show-sdk-path)"
SWIFT_VERSION="$(swiftc --version)"
if [[ "$SWIFT_VERSION" == *"Swift version 6.1"* ]] && [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk ]; then
 SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk
fi
TEST_TEMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TEMP"' EXIT
for test in ColorAndResolution FolderImport; do
 swiftc -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$TEST_TEMP/cache" Source/Engine.swift "Tests/$test.swift" -o "$TEST_TEMP/$test"
 "$TEST_TEMP/$test" "$TEST_TEMP/$test-data"
done
