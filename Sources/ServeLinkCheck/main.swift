// A link check, not a program. `swift build` compiles library targets without ever linking
// them, so an undefined symbol — the SwiftPM resource-bundle accessor is the one that bites,
// since its name follows the SwiftPM target rather than the class prefix — survives a green
// build and only fails for whoever first tries to consume the package. Touching a symbol
// from each module and linking an executable is what catches that in CI.
import Foundation
import Serve
import ServeUploader
import ServeWebDAV

let directory = NSTemporaryDirectory()
let server = SRVServer()
let uploader = SRVUploader(uploadDirectory: directory)   // reaches the resource accessor
let dav = SRVDAVServer(uploadDirectory: directory)
print("linked: \(type(of: server)), \(type(of: uploader)), \(type(of: dav)); reserved=\(SRVServer.reservedInMemoryByteCount)")
