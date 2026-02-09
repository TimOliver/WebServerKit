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
- Directory watcher using `dispatch_source` (DISPATCH_SOURCE_TYPE_VNODE) for external filesystem changes
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
data: {"type":"external","path":"/"}
```

**Limitation:** Directory watcher only monitors the root upload directory. Subdirectory changes require the file operation to happen in the currently viewed directory to trigger updates.

### Framework Linking

System frameworks are linked via `OTHER_LDFLAGS` in project build settings:
- Foundation, CoreServices (weak), SystemConfiguration, CFNetwork, libxml2, libz
- UIKit is conditionally linked only for iOS/tvOS SDKs

### iOS Files App Integration

`Examples/iOS/Info.plist` includes:
- `UIFileSharingEnabled` - Makes Documents visible in iTunes/Finder
- `LSSupportsOpeningDocumentsInPlace` - Makes app appear in Files app
