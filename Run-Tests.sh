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

# Nothing built here is distributed, and the example target is configured with a specific
# development team, so a real certificate would have to exist on every machine that runs
# this — it does not on a CI runner ("No signing certificate Mac Development found").
# Ad-hoc ("-") rather than CODE_SIGNING_ALLOWED=NO, because an entirely unsigned binary
# will not execute on Apple silicon and the trace runner has to actually run.
SIGNING=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)

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
xcodebuild test -project GCDWebServer.xcodeproj -scheme "GCDWebServers (Mac)" -configuration Debug "SYMROOT=$BUILD_DIR" "${SIGNING[@]}"

echo "=== Recorded traces ==="
xcodebuild build -project GCDWebServer.xcodeproj -sdk macosx -target "GCDWebServer (Mac)" -configuration Release "SYMROOT=$BUILD_DIR" "${SIGNING[@]}"

runTests htmlForm Tests/HTMLForm
runTests htmlFileUpload Tests/HTMLFileUpload
runTests webServer Tests/WebServer
runTests webDAV Tests/WebDAV-Transmit
runTests webDAV Tests/WebDAV-Cyberduck
runTests webDAV Tests/WebDAV-Finder
runTests webUploader Tests/WebUploader
runTests webServer Tests/WebServer-Sample-Movie Tests/Sample-Movie.mp4

echo "=== Release builds ==="
xcodebuild build -project GCDWebServer.xcodeproj -scheme "GCDWebServers (Mac)" -configuration Release "SYMROOT=$BUILD_DIR" "${SIGNING[@]}"
xcodebuild build -project GCDWebServer.xcodeproj -scheme "GCDWebServers (iOS)" -configuration Release -destination 'generic/platform=iOS Simulator' "SYMROOT=$BUILD_DIR" "${SIGNING[@]}"
xcodebuild build -project GCDWebServer.xcodeproj -scheme "GCDWebServers (tvOS)" -configuration Release -destination 'generic/platform=tvOS Simulator' "SYMROOT=$BUILD_DIR" "${SIGNING[@]}"

echo "=== Swift Package Manager ==="
# The package layout is fragile in ways a plain Xcode build cannot see: the public headers
# are exposed to SwiftPM through a directory of symlinks, and reaching the same header by
# two paths makes clang report duplicate interfaces. Building here catches that.
swift build

echo ""
echo "All tests completed successfully."
