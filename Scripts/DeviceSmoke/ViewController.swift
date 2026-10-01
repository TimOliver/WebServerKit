// Disposable native-device host. Only this run's synthetic share is served over HTTP.
import UIKit
import WebServerKit
import Darwin

final class DeviceSmokeConnection: WSKConnection {
  private static let counterLock = NSLock()
  private static var accepted = 0
  private static var closed = 0
  private static var live = 0
  private var counted = false

  override func open() -> Bool {
    guard super.open() else { return false }
    Self.counterLock.lock()
    counted = true
    Self.accepted += 1
    Self.live += 1
    Self.counterLock.unlock()
    return true
  }

  override func close() {
    Self.counterLock.lock()
    if counted {
      counted = false
      Self.closed += 1
      Self.live -= 1
    }
    Self.counterLock.unlock()
    super.close()
  }

  static func snapshot() -> [String: Int] {
    counterLock.lock()
    defer { counterLock.unlock() }
    return ["accepted": accepted, "closed": closed, "connections": live]
  }
}

final class ViewController: UIViewController {
  @IBOutlet var label: UILabel?

  private var uploader: WSKWebUploader?
  private var dav: WSKWebDAVServer?
  private var timer: Timer?
  private var shareURL: URL?
  private var resumableURL: URL?
  private var reportURL: URL?
  private var runID = ""
  private var runStatus = "starting"
  private var failure: String?
  private var uploaderPort: UInt = 0
  private var davPort: UInt = 0
  private var lifecycleEvents = [[String: Any]]()

  override func viewDidLoad() {
    super.viewDidLoad()
    UIApplication.shared.isIdleTimerDisabled = UIApplication.shared.applicationState == .active
    let notifications = NotificationCenter.default
    notifications.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    notifications.addObserver(self, selector: #selector(willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    notifications.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    notifications.addObserver(self, selector: #selector(willResignActive), name: UIApplication.willResignActiveNotification, object: nil)

    do {
      try startProbe()
      runStatus = "ready"
      recordLifecycle("started")
      startTimer()
    } catch {
      uploader?.stop()
      dav?.stop()
      runStatus = "failed"
      failure = error.localizedDescription
      recordLifecycle("startup_failed")
    }
  }

  deinit {
    timer?.invalidate()
    UIApplication.shared.isIdleTimerDisabled = false
    NotificationCenter.default.removeObserver(self)
    uploader?.stop()
    dav?.stop()
  }

  private func startProbe() throws {
    let manager = FileManager.default
    let documents = try manager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    reportURL = documents.appendingPathComponent("probe.json")
    let arguments = ProcessInfo.processInfo.arguments
    let flags = arguments.indices.filter { arguments[$0] == "--probe-run-id" }
    guard flags.count == 1, let index = flags.first, index + 1 < arguments.count,
          let identifier = UUID(uuidString: arguments[index + 1]),
          identifier.uuidString.caseInsensitiveCompare(arguments[index + 1]) == .orderedSame else {
      throw probeError("Supply exactly one --probe-run-id followed by a UUID")
    }
    runID = arguments[index + 1]
    let directory = documents.appendingPathComponent("Share-\(runID)", isDirectory: true)
    guard !manager.fileExists(atPath: directory.path) else {
      throw probeError("This run directory already exists; launch with a new UUID")
    }
    try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: nil)
    shareURL = directory
    try Data(repeating: 0x5a, count: 8 * 1024 * 1024).write(to: directory.appendingPathComponent("asset.bin"), options: .atomic)
    let identity = ["run_id": runID, "bundle_id": Bundle.main.bundleIdentifier ?? ""]
    try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys]).write(to: directory.appendingPathComponent("probe-identity.json"), options: .atomic)

    // Keep every partial and receipt outside the HTTP/DAV share, scoped to this run.
    let sessions = documents.appendingPathComponent("Sessions-\(runID)", isDirectory: true)
    guard !manager.fileExists(atPath: sessions.path) else {
      throw probeError("This session directory already exists; launch with a new UUID")
    }
    try manager.createDirectory(at: sessions, withIntermediateDirectories: false,
                                attributes: [.posixPermissions: 0o700])
    resumableURL = sessions
    let uploadServer = WSKWebUploader(uploadDirectory: directory.path)
    uploadServer.resumableUploadDirectory = sessions.path
    let davServer = WSKWebDAVServer(uploadDirectory: directory.path)
    uploader = uploadServer
    dav = davServer
    let options: [String: Any] = [
      WSKOption_Port: 0,
      WSKOption_ConnectionClass: DeviceSmokeConnection.self,
      WSKOption_AutomaticallySuspendInBackground: true,
      WSKOption_ConnectionKeepAliveTimeout: 2.0,
      WSKOption_ConnectionIdleTimeout: 120.0,
    ]
    var uploadOptions = options
    uploadOptions[WSKOption_BonjourName] = "WSK Probe HTTP \(runID.prefix(8))"
    uploadOptions[WSKOption_BonjourType] = "_http._tcp"
    try uploadServer.start(options: uploadOptions)
    var davOptions = options
    davOptions[WSKOption_BonjourName] = "WSK Probe DAV \(runID.prefix(8))"
    davOptions[WSKOption_BonjourType] = "_webdav._tcp"
    davOptions[WSKOption_BonjourTXTData] = ["path": "/"]
    try davServer.start(options: davOptions)
  }

  private func probeError(_ message: String) -> NSError {
    NSError(domain: "DeviceSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }

  private func startTimer() {
    guard timer == nil, runStatus == "ready", UIApplication.shared.applicationState != .background else { return }
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      guard UIApplication.shared.applicationState != .background else { return }
      self?.writeSnapshot(reason: "foreground_timer")
    }
  }

  @objc private func didEnterBackground() {
    UIApplication.shared.isIdleTimerDisabled = false
    timer?.invalidate()
    timer = nil
    recordLifecycle("did_enter_background")
  }

  @objc private func willEnterForeground() {
    recordLifecycle("will_enter_foreground")
  }

  @objc private func didBecomeActive() {
    UIApplication.shared.isIdleTimerDisabled = true
    recordLifecycle("did_become_active")
    startTimer()
  }

  @objc private func willResignActive() {
    UIApplication.shared.isIdleTimerDisabled = false
  }

  private func recordLifecycle(_ event: String) {
    lifecycleEvents.append(["event": event, "timestamp": Date().timeIntervalSince1970])
    if lifecycleEvents.count > 32 { lifecycleEvents.removeFirst(lifecycleEvents.count - 32) }
    print("[DeviceSmoke] \(event) run=\(runID)")
    writeSnapshot(reason: event)
  }

  private func writeSnapshot(reason: String) {
    guard let reportURL = reportURL else { return }
    let address = wifiIPv4()
    if let server = uploader, server.isRunning { uploaderPort = server.port }
    if let server = dav, server.isRunning { davPort = server.port }
    let state: String
    switch UIApplication.shared.applicationState {
    case .active: state = "active"
    case .inactive: state = "inactive"
    case .background: state = "background"
    @unknown default: state = "unknown"
    }
    var report: [String: Any] = [
      "run_id": runID,
      "bundle_id": Bundle.main.bundleIdentifier ?? "",
      "pid": Int(getpid()),
      "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
      "app_state": state,
      "status": runStatus,
      "sample_timestamp": Date().timeIntervalSince1970,
      "sample_reason": reason,
      "uptime_seconds": ProcessInfo.processInfo.systemUptime,
      "sampling_scope": "Foreground timer and lifecycle callbacks only; no samples while suspended",
      "configuration": ["idle_timeout_seconds": 120, "keep_alive_timeout_seconds": 2, "automatically_suspend_in_background": true],
      "wifi_ipv4": address.map { $0 as Any } ?? NSNull(),
      "uploader_port": uploaderPort,
      "dav_port": davPort,
      "uploader_running": uploader?.isRunning ?? false,
      "dav_running": dav?.isRunning ?? false,
      "reserved_bytes": WSKWebServer.reservedInMemoryByteCount,
      "descriptors": descriptorCount(),
      "share_inventory": shareURL.map { inventory(at: $0) } ?? ["entries": [], "errors": []],
      "temp_inventory": inventory(at: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)),
      "resumable_inventory": resumableURL.map { inventory(at: $0) } ?? ["entries": [], "errors": []],
      "lifecycle_events": lifecycleEvents,
    ]
    for (key, value) in DeviceSmokeConnection.snapshot() { report[key] = value }
    if let failure = failure { report["error"] = failure }
    if let url = uploader?.bonjourServerURL { report["uploader_bonjour_url"] = url.absoluteString }
    if let url = dav?.bonjourServerURL { report["dav_bonjour_url"] = url.absoluteString }
    do {
      let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: reportURL, options: .atomic)
    } catch {
      print("[DeviceSmoke] Failed writing probe.json: \(error.localizedDescription)")
      label?.text = "Probe reporting failed: \(error.localizedDescription)"
      return
    }
    if let failure = failure {
      label?.text = "Probe failed: \(failure)"
    } else {
      label?.text = "Wi-Fi: \(address ?? "unavailable")\nHTTP: \(uploaderPort)   DAV: \(davPort)\nRun: \(runID.prefix(8))\nSynthetic test files only"
    }
  }

  // Enumerate only the new share and this disposable application's own temp directory.
  // Symlinks are recorded, never followed into another location.
  private func inventory(at directory: URL) -> [String: Any] {
    let root = directory.resolvingSymlinksInPath()
    var entries = [[String: Any]]()
    var errors = [String]()
    var inspectedEntries = 0
    var pending: [(url: URL, relative: String, depth: Int)] = [(root, "", 0)]
    let maximumEntries = 10_000
    let maximumDepth = 32
    while let current = pending.popLast() {
      do {
        // Foundation may change /var to /private/var between URLs. Relative
        // names come from entries, never from slicing an absolute path prefix.
        let children = try FileManager.default.contentsOfDirectory(at: current.url, includingPropertiesForKeys: nil, options: [])
        guard children.count <= maximumEntries - inspectedEntries else {
          errors.append("Application inventory exceeds \(maximumEntries) entries")
          break
        }
        for item in children {
          inspectedEntries += 1
          let name = item.lastPathComponent
          let relative = current.relative.isEmpty ? name : current.relative + "/" + name
          var info = stat()
          // lstat observes the directory entry itself, including symlinks.
          guard item.withUnsafeFileSystemRepresentation({ path in
            guard let path = path else { return false }
            return lstat(path, &info) == 0
          }) else {
            errors.append("Cannot inspect application entry: \(relative)")
            continue
          }
          let mode = info.st_mode & mode_t(S_IFMT)
          let type: String
          if mode == mode_t(S_IFLNK) {
            type = "symlink"
          } else if mode == mode_t(S_IFDIR) {
            type = "directory"
            if current.depth < maximumDepth {
              pending.append((item, relative, current.depth + 1))
            } else {
              errors.append("Application inventory exceeds depth \(maximumDepth): \(relative)")
            }
          } else if mode == mode_t(S_IFREG) {
            type = "file"
          } else {
            type = "other"
          }
          entries.append(["path": relative, "type": type, "size": info.st_size])
        }
      } catch {
        errors.append("\(current.relative.isEmpty ? "." : current.relative): \(error.localizedDescription)")
      }
    }
    entries.sort { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
    return ["entries": entries, "errors": errors]
  }

  private func wifiIPv4() -> String? {
    var first: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&first) == 0 else { return nil }
    defer { freeifaddrs(first) }
    var cursor = first
    while let interface = cursor {
      defer { cursor = interface.pointee.ifa_next }
      guard String(cString: interface.pointee.ifa_name) == "en0",
            let address = interface.pointee.ifa_addr,
            address.pointee.sa_family == UInt8(AF_INET),
            (interface.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
      var ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
      var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
      if inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
        return String(cString: buffer)
      }
    }
    return nil
  }

  private func descriptorCount() -> Int {
    // F_GETFD examines this process's descriptors without opening a counting descriptor.
    var limits = rlimit()
    guard getrlimit(RLIMIT_NOFILE, &limits) == 0,
          limits.rlim_cur > 0, limits.rlim_cur <= 65_536 else { return -1 }
    let limit = Int32(limits.rlim_cur)
    var count = 0
    for descriptor in 0..<limit {
      if fcntl(descriptor, F_GETFD) >= 0 { count += 1 }
    }
    return count
  }
}
