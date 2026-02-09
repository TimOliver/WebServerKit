# WebServerKit

A fork of GCDWebServer with additional features for iOS/macOS web serving.

## Build Commands

```bash
# Build Mac framework
xcodebuild -project GCDWebServer.xcodeproj -scheme "GCDWebServers (Mac)" -configuration Debug build

# Build iOS framework
xcodebuild -project GCDWebServer.xcodeproj -scheme "GCDWebServers (iOS)" -configuration Debug -destination 'generic/platform=iOS Simulator' build

# Build tvOS framework
xcodebuild -project GCDWebServer.xcodeproj -scheme "GCDWebServers (tvOS)" -configuration Debug -destination 'generic/platform=tvOS Simulator' build
```

## Project Structure

- `Sources/GCDWebServer/` - Core web server implementation
- `Sources/GCDWebUploader/` - File upload/download web interface
- `Sources/GCDWebDAVServer/` - WebDAV server implementation
- `Examples/iOS/` - iOS example app
- `Examples/macOS/` - macOS example app
- `Framework/` - Framework configuration files

## Recent Changes

### Server-Sent Events (SSE) for GCDWebUploader

Added live browser updates when files change on the device.

**Files modified:**
- `Sources/GCDWebUploader/GCDWebUploader.h` - Added `serverSentEventsEnabled` property
- `Sources/GCDWebUploader/GCDWebUploader.m` - SSE infrastructure implementation
- `Sources/GCDWebUploader/GCDWebUploader.bundle/Contents/Resources/js/index.js` - EventSource client

**Features:**
- `/events` endpoint streaming SSE with content-type `text/event-stream`
- Heartbeat comments every 15 seconds to keep connections alive
- Broadcasts change events for: upload, delete, move, create operations
- File system observation using `NSFilePresenter` for external changes (Files app, etc.)
  - Monitors subdirectories recursively via `presentedSubitemDidChangeAtURL:`
  - Coalesces rapid changes with 100ms timer to avoid flooding
  - Sends specific directory paths so browser only reloads when current folder is affected
- JavaScript EventSource with auto-reconnect on connection errors

**Event format:**
```
event: change
data: {"type":"upload","path":"/file.txt"}

event: change
data: {"type":"delete","path":"/file.txt"}

event: change
data: {"type":"move","oldPath":"/a.txt","newPath":"/b.txt"}

event: change
data: {"type":"create","path":"/NewFolder/"}

event: change
data: {"type":"external","path":"/Documents/"}
```

**Smart reloading:** The browser only reloads when the changed directory matches the currently viewed path.

### Framework Linking

System frameworks are linked via `OTHER_LDFLAGS` in project build settings:
- Foundation, CoreServices (weak), SystemConfiguration, CFNetwork, libxml2, libz
- UIKit is conditionally linked only for iOS/tvOS SDKs

### iOS Files App Integration

`Examples/iOS/Info.plist` includes:
- `UIFileSharingEnabled` - Makes Documents visible in iTunes/Finder
- `LSSupportsOpeningDocumentsInPlace` - Makes app appear in Files app

### Background Mode

`Examples/iOS/ViewController.swift` starts the server with:
- `GCDWebServerOption_AutomaticallySuspendInBackground: false`
- This gives ~30 seconds of background execution time before iOS suspends the app
