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
  private let launchID = UUID().uuidString
  private var resumedExistingRun = false
  private var runStatus = "starting"
  private var failure: String?
  private var uploaderPort: UInt = 0
  private var davPort: UInt = 0
  private var lifecycleEvents = [[String: Any]]()
  private var protectedDataProbe = false
  private var protectedSession: [String: Any]?
  private var protectedDataResults = [[String: Any]]()
  private var protectedProbeRunning = false
  private var protectedBackgroundTask = UIBackgroundTaskIdentifier.invalid

  override func viewDidLoad() {
    super.viewDidLoad()
    UIApplication.shared.isIdleTimerDisabled = UIApplication.shared.applicationState == .active
    let notifications = NotificationCenter.default
    notifications.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    notifications.addObserver(self, selector: #selector(willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    notifications.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    notifications.addObserver(self, selector: #selector(willResignActive), name: UIApplication.willResignActiveNotification, object: nil)
    notifications.addObserver(self, selector: #selector(protectedDataWillBecomeUnavailable), name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
    notifications.addObserver(self, selector: #selector(protectedDataDidBecomeAvailable), name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)

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
    protectedDataProbe = arguments.contains("--probe-protected-data")
    let flags = arguments.indices.filter { arguments[$0] == "--probe-run-id" }
    guard flags.count == 1, let index = flags.first, index + 1 < arguments.count,
          let identifier = UUID(uuidString: arguments[index + 1]),
          identifier.uuidString.caseInsensitiveCompare(arguments[index + 1]) == .orderedSame else {
      throw probeError("Supply exactly one --probe-run-id followed by a UUID")
    }
    runID = arguments[index + 1]
    resumedExistingRun = arguments.contains("--resume-probe-run")
    let directory = documents.appendingPathComponent("Share-\(runID)", isDirectory: true)
    let identity = ["run_id": runID, "bundle_id": Bundle.main.bundleIdentifier ?? ""]
    let sessions = documents.appendingPathComponent("Sessions-\(runID)", isDirectory: true)
    if resumedExistingRun {
      // Explicitly reopen only this synthetic run. Never recreate fixtures: their
      // bytes, inode/ETag and the real persisted manifests are the recovery oracle.
      for path in [directory, sessions] {
        var info = stat()
        guard lstat(path.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
          throw probeError("Resume requires existing real run directories")
        }
      }
      let identityURL = directory.appendingPathComponent("probe-identity.json")
      let assetURL = directory.appendingPathComponent("asset.bin")
      for path in [identityURL, assetURL] {
        var info = stat()
        guard lstat(path.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              path != assetURL || info.st_size == 8 * 1024 * 1024,
              path == assetURL || info.st_size <= 4096 else {
          throw probeError("Resume fixture is missing or has changed type/size")
        }
      }
      let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: identityURL)) as? [String: String]
      guard saved == identity else { throw probeError("Resume identity does not match this run") }
    } else {
      guard !manager.fileExists(atPath: directory.path), !manager.fileExists(atPath: sessions.path) else {
        throw probeError("This run already exists; use a new UUID or explicit --resume-probe-run")
      }
      try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: nil)
      try Data(repeating: 0x5a, count: 8 * 1024 * 1024).write(to: directory.appendingPathComponent("asset.bin"), options: .atomic)
      try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys]).write(to: directory.appendingPathComponent("probe-identity.json"), options: .atomic)
      try manager.createDirectory(at: sessions, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
    }
    shareURL = directory
    // Keep every partial and receipt outside the HTTP/DAV share, scoped to this run.
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
      self?.armProtectedSessionIfReady()
      self?.writeSnapshot(reason: "foreground_timer")
    }
  }

  @objc private func didEnterBackground() {
    UIApplication.shared.isIdleTimerDisabled = false
    timer?.invalidate()
    timer = nil
    if protectedDataProbe && protectedSession != nil && protectedBackgroundTask == .invalid {
      // This disposable probe needs enough time to observe key eviction. The
      // production server keeps its normal background policy unchanged.
      protectedBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Protected synthetic upload probe") { [weak self] in
        self?.endProtectedBackgroundTask()
      }
    }
    recordLifecycle("did_enter_background")
  }

  @objc private func willEnterForeground() {
    recordLifecycle("will_enter_foreground")
  }

  @objc private func didBecomeActive() {
    UIApplication.shared.isIdleTimerDisabled = true
    recordLifecycle("did_become_active")
    startTimer()
    endProtectedBackgroundTask()
  }

  @objc private func willResignActive() {
    UIApplication.shared.isIdleTimerDisabled = false
  }

  private func endProtectedBackgroundTask() {
    if protectedBackgroundTask != .invalid {
      UIApplication.shared.endBackgroundTask(protectedBackgroundTask)
      protectedBackgroundTask = .invalid
    }
  }

  // Only the opt-in, fresh, synthetic run receives complete-protection files.
  // The saved protocol offset must be stable before those attributes are set.
  private func armProtectedSessionIfReady() {
    guard protectedDataProbe, protectedSession == nil, let directory = resumableURL else { return }
    do {
      let candidates = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      for candidate in candidates where UUID(uuidString: candidate.lastPathComponent) != nil {
        let manifestURL = candidate.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let offset = manifest["offset"] as? Int, offset == 1024 * 1024,
              manifest["state"] as? String == "active",
              let metadata = manifest["metadata"] as? [String: String],
              metadata["filename"]?.hasPrefix("smoke-\(runID.lowercased())-") == true else { continue }
        let payloadURL = candidate.appendingPathComponent("payload")
        for file in [manifestURL, payloadURL] {
          try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
          let actual = try FileManager.default.attributesOfItem(atPath: file.path)[.protectionKey] as? FileProtectionType
          guard actual == .complete else { throw probeError("Synthetic file did not acquire complete protection") }
        }
        // Exercise cleanup too: old directory mtime must not make unreadable
        // but still-live manifest state disposable.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -172800)], ofItemAtPath: candidate.path)
        protectedSession = ["key": candidate.lastPathComponent, "offset": offset,
                            "length": manifest["length"] ?? 0, "metadata": manifest["metadataHeader"] ?? "",
                            "protection": FileProtectionType.complete.rawValue,
                            "armed_at": Date().timeIntervalSince1970]
        recordLifecycle("protected_session_armed")
        return
      }
    } catch {
      protectedDataResults.append(["phase": "arming", "error": error.localizedDescription])
    }
  }

  @objc private func protectedDataWillBecomeUnavailable() {
    recordLifecycle("protected_data_will_become_unavailable")
    guard protectedDataProbe, protectedSession != nil, !protectedProbeRunning else { return }
    protectedProbeRunning = true
    probeUnavailableData(deadline: Date().addingTimeInterval(20))
  }

  private func probeUnavailableData(deadline: Date) {
    guard Date() <= deadline else {
      protectedDataResults.append(["phase": "inconclusive",
        "error": "No file-protection denial was observed within the execution window; suspension or a delayed lock notification may have prevented the probe",
        "probe_requested_at": deadline.timeIntervalSince1970 - 20,
        "callback_observed_at": Date().timeIntervalSince1970,
        "protected_data_available_now": UIApplication.shared.isProtectedDataAvailable,
        "background_time_remaining_seconds": backgroundTimeRemaining()])
      writeSnapshot(reason: "protected_data_probe_inconclusive")
      return
    }
    guard !UIApplication.shared.isProtectedDataAvailable else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.probeUnavailableData(deadline: deadline) }
      return
    }
    guard let session = protectedSession, let directory = resumableURL,
          let key = session["key"] as? String else { return }
    let sessionURL = directory.appendingPathComponent(key)
    let manifestURL = sessionURL.appendingPathComponent("manifest.json")
    let file = open(manifestURL.path, O_RDONLY | O_CLOEXEC)
    let readError = file < 0 ? errno : 0
    if file >= 0 { close(file) }
    let port = uploaderPort
    let observedAt = Date().timeIntervalSince1970
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let status = Self.localProtocolStatus(port: port, method: "HEAD", key: key)
      var manifestInfo = stat()
      var payloadInfo = stat()
      let manifestRetained = lstat(manifestURL.path, &manifestInfo) == 0
      let payloadRetained = lstat(sessionURL.appendingPathComponent("payload").path, &payloadInfo) == 0
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.protectedDataResults.append(["phase": "locked", "observed_at": observedAt,
          "protected_data_available": false, "read_errno": Int(readError), "http_status": status,
          "manifest_retained": manifestRetained, "payload_retained": payloadRetained,
          "payload_size": payloadRetained ? payloadInfo.st_size : -1,
          "key": key, "complete_protection": true])
        self.recordLifecycle("protected_data_denial_probed")
      }
    }
  }

  @objc private func protectedDataDidBecomeAvailable() {
    if protectedDataProbe, let session = protectedSession, let key = session["key"] as? String,
       let directory = resumableURL {
      do {
        let data = try Data(contentsOf: directory.appendingPathComponent(key).appendingPathComponent("manifest.json"))
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        protectedDataResults.append(["phase": "unlocked", "observed_at": Date().timeIntervalSince1970,
          "key": key, "protected_data_available": UIApplication.shared.isProtectedDataAvailable,
          "offset": manifest?["offset"] ?? -1])
      } catch {
        protectedDataResults.append(["phase": "unlocked", "error": error.localizedDescription])
      }
    }
    recordLifecycle("protected_data_did_become_available")
  }

  // A loopback request stays observable without depending on Wi-Fi while the
  // phone is locked. This bounded client only addresses this process's server.
  private static func localProtocolStatus(port: UInt, method: String, key: String) -> Int {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return -1 }
    defer { close(descriptor) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSignal: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else { return -2 }
    let request = Data("\(method) /uploads/\(key) HTTP/1.1\r\nHost: localhost\r\nTus-Resumable: 1.0.0\r\nConnection: close\r\n\r\n".utf8)
    var sent = 0
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while sent < request.count && ProcessInfo.processInfo.systemUptime < deadline {
      let count = request.withUnsafeBytes { send(descriptor, $0.baseAddress?.advanced(by: sent), $0.count - sent, 0) }
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { return -3 }
      sent += count
    }
    guard sent == request.count else { return -3 }
    var response = Data()
    while response.count < 8192 && ProcessInfo.processInfo.systemUptime < deadline {
      var bytes = [UInt8](repeating: 0, count: min(1024, 8192 - response.count))
      let count = recv(descriptor, &bytes, bytes.count, 0)
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { return -4 }
      response.append(contentsOf: bytes.prefix(count))
      if let end = response.range(of: Data([13, 10])) {
        guard let line = String(data: response[..<end.lowerBound], encoding: .utf8) else { return -5 }
        return Int(line.split(separator: " ").dropFirst().first ?? "") ?? -5
      }
    }
    return -4
  }

  private func recordLifecycle(_ event: String) {
    lifecycleEvents.append(["event": event, "timestamp": Date().timeIntervalSince1970,
      "connections": DeviceSmokeConnection.snapshot()["connections"] ?? -1,
      "wifi_ipv4": wifiIPv4().map { $0 as Any } ?? NSNull(),
      "protected_data_available": UIApplication.shared.isProtectedDataAvailable,
      "background_time_remaining_seconds": backgroundTimeRemaining()])
    if lifecycleEvents.count > 32 { lifecycleEvents.removeFirst(lifecycleEvents.count - 32) }
    print("[DeviceSmoke] \(event) run=\(runID)")
    writeSnapshot(reason: event)
  }

  private func backgroundTimeRemaining() -> Any {
    let remaining = UIApplication.shared.backgroundTimeRemaining
    // UIKit uses an effectively unbounded sentinel in the foreground. Preserve
    // limited execution time as seconds; null means no finite estimate here.
    if remaining.isFinite && remaining < Double.greatestFiniteMagnitude { return remaining }
    return NSNull()
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
      "launch_id": launchID,
      "resumed_existing_run": resumedExistingRun,
      "bundle_id": Bundle.main.bundleIdentifier ?? "",
      "pid": Int(getpid()),
      "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
      "app_state": state,
      "status": runStatus,
      "sample_timestamp": Date().timeIntervalSince1970,
      "sample_reason": reason,
      "uptime_seconds": ProcessInfo.processInfo.systemUptime,
      "sampling_scope": "Foreground timer and lifecycle callbacks only; no samples while suspended",
      "background_time_remaining_seconds": backgroundTimeRemaining(),
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
      "protected_data_available": UIApplication.shared.isProtectedDataAvailable,
      "protected_data_probe_enabled": protectedDataProbe,
      "protected_data_results": protectedDataResults,
    ]
    if let session = protectedSession { report["protected_session"] = session }
    for (key, value) in DeviceSmokeConnection.snapshot() { report[key] = value }
    if let failure = failure { report["error"] = failure }
    if let url = uploader?.bonjourServerURL { report["uploader_bonjour_url"] = url.absoluteString }
    if let url = dav?.bonjourServerURL { report["dav_bonjour_url"] = url.absoluteString }
    do {
      let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      // This report contains only synthetic test metadata and must survive lock
      // so the host can retrieve evidence of denied protected-file reads.
      try data.write(to: reportURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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
