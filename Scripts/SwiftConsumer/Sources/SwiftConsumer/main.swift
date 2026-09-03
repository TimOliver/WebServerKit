// See Package.swift. Everything here is top-level code, which Swift 6 treats as running on
// the main actor — exactly where an app registers its handlers — so a closure the library
// imports as non-Sendable inherits that isolation and traps when a connection queue calls it.
import Foundation
import WebServerKit
import WebServerKitDAV
import WebServerKitUploader

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wsk-swift-consumer-\(getpid())").path
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: directory) }

let uploader = WSKWebUploader(uploadDirectory: directory)
let dav = WSKWebDAVServer(uploadDirectory: directory)  // Links the third module; never started

uploader.addHandler(forMethod: "GET", path: "/consumer", request: WSKRequest.self) { request in
    return WSKDataResponse(text: "sync \(request.path)")
}
uploader.addHandler(forMethod: "GET", path: "/consumer-async", request: WSKRequest.self) { request, completion in
    let text = "async \(request.path)"
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(10)) {
        completion(WSKDataResponse(text: text))
    }
}

try uploader.start(options: [WSKOption_Port: 0, WSKOption_BindToLocalhost: true, WSKOption_BonjourName: ""])
guard let base = uploader.serverURL else {
    fatalError("the server started but reports no URL")
}

// A blocking GET; the session's callback runs off the main thread, so waiting here is safe.
@MainActor func fetch(_ path: String) -> (status: Int, body: String) {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: (status: Int, body: String) = (0, "")
    let url = (path == "/") ? base : URL(string: String(path.dropFirst()), relativeTo: base)!
    URLSession.shared.dataTask(with: url) { data, response, _ in
        result = ((response as? HTTPURLResponse)?.statusCode ?? 0, String(data: data ?? Data(), encoding: .utf8) ?? "")
        semaphore.signal()
    }.resume()
    semaphore.wait()
    return result
}

var failures = [String]()
@MainActor func expect(_ path: String, status: Int, body: String? = nil) {
    let reply = fetch(path)
    if reply.status != status || (body != nil && reply.body != body) {
        failures.append("\(path): got \(reply.status) \(reply.body.prefix(60).debugDescription), wanted \(status) \(body ?? "")")
    }
}

expect("/consumer", status: 200, body: "sync /consumer")                // A closure registered from main-actor code, called on a connection queue
expect("/consumer-async", status: 200, body: "async /consumer-async")   // The same for the async form and its completion block
expect("/", status: 200)                                                // The page: served from the resource bundle the accessor located
expect("/css/index.css", status: 200)

uploader.stop()
if failures.isEmpty {
    print("consumer ok: \(type(of: uploader)), \(type(of: dav)); reserved=\(WSKWebServer.reservedInMemoryByteCount)")
} else {
    for failure in failures { print("consumer FAILED \(failure)") }
    exit(1)
}
