#!/bin/bash -eu -o pipefail

# The single entry point for everything CI runs, so "it passes locally" and "it passes
# in CI" cannot drift apart. Three things happen here:
#
#   1. the XCTest suite (Framework/Tests.m), built with the address sanitizer
#   2. the recorded-trace corpus under Tests/, replayed against a real server
#   3. a Release build of the shipping framework for every platform
#
# Deployment targets are deliberately NOT overridden. This script used to build with
# MACOSX_DEPLOYMENT_TARGET=10.7 and IPHONEOS_DEPLOYMENT_TARGET=8.0 to check the oldest
# supported OS, but no current toolchain can link those (there is no libarclite for
# them), so those steps could only ever fail. The project's own floors are the thing to
# test, and they need no hardcoded version here to go stale.

BUILD_DIR="$(pwd)/build"
PAYLOAD_ZIP="Tests/Payload.zip"
PAYLOAD_DIR="$BUILD_DIR/Payload"
TRACE_RUNNER="$BUILD_DIR/Release/GCDWebServer"

# Replays one recorded suite. The payload is re-extracted each time because several
# suites mutate it (PUT, MOVE, DELETE), and directory timestamps are normalized because
# a ZIP does not preserve them and the traces assert on Last-Modified. touch(1) rather
# than SetFile(1): it is in every base install, whereas SetFile ships with Xcode and is
# missing from some CI images.
function runTests {
  local mode="$1" tests="$2" file="${3:-}"

  rm -rf "$PAYLOAD_DIR"
  ditto -x -k "$PAYLOAD_ZIP" "$PAYLOAD_DIR"
  TZ=GMT find "$PAYLOAD_DIR" -type d -exec touch -t 201401010000.00 '{}' \;

  if [ -n "$file" ]; then
    cp -f "$file" "$PAYLOAD_DIR/Payload"
    TZ=GMT touch -t 201401010000.00 "$PAYLOAD_DIR/Payload/$(basename "$file")"
  fi

  echo "--- $tests"
  logLevel=2 "$TRACE_RUNNER" -mode "$mode" -root "$PAYLOAD_DIR/Payload" -tests "$tests"
}

rm -rf "$BUILD_DIR"

echo "=== Unit tests ==="
xcodebuild test -project GCDWebServer.xcodeproj -scheme "GCDWebServers (Mac)" -configuration Debug "SYMROOT=$BUILD_DIR"

echo "=== Recorded traces ==="
xcodebuild build -project GCDWebServer.xcodeproj -sdk macosx -target "GCDWebServer (Mac)" -configuration Release "SYMROOT=$BUILD_DIR"

runTests htmlForm Tests/HTMLForm
runTests htmlFileUpload Tests/HTMLFileUpload
runTests webServer Tests/WebServer
runTests webDAV Tests/WebDAV-Transmit
runTests webDAV Tests/WebDAV-Cyberduck
runTests webDAV Tests/WebDAV-Finder
runTests webUploader Tests/WebUploader
runTests webServer Tests/WebServer-Sample-Movie Tests/Sample-Movie.mp4

echo "=== Release builds ==="
xcodebuild build -project GCDWebServer.xcodeproj -scheme "GCDWebServers (Mac)" -configuration Release "SYMROOT=$BUILD_DIR"
xcodebuild build -project GCDWebServer.xcodeproj -scheme "GCDWebServers (iOS)" -configuration Release -destination 'generic/platform=iOS Simulator' "SYMROOT=$BUILD_DIR"
xcodebuild build -project GCDWebServer.xcodeproj -scheme "GCDWebServers (tvOS)" -configuration Release -destination 'generic/platform=tvOS Simulator' "SYMROOT=$BUILD_DIR"

echo ""
echo "All tests completed successfully."
