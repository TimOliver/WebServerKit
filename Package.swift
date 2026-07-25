// swift-tools-version:5.9

import PackageDescription

// The public headers are spread across Core/, Requests/ and Responses/, and they import
// each other by bare filename as the fallback arm of
// `#if __has_include(<GCDWebServers/…>)`. Naming the core module GCDWebServers — the same
// name the framework uses — makes the angle-bracket arm win instead, which resolves through
// Sources/GCDWebServer/include/GCDWebServers (a directory of symlinks to the real headers,
// deliberately excluding GCDWebServerPrivate.h). Without that the module cannot be built by
// a Swift consumer at all: the umbrella would drag in the private header, which imports a
// dozen others it cannot find.
//
// The .m files still use bare quoted imports, hence the per-target header search paths.
let coreSources: [CSetting] = [
    .headerSearchPath("Core"),
    .headerSearchPath("Requests"),
    .headerSearchPath("Responses")
]

// The .m files in the sibling targets import core headers by bare filename, which SwiftPM
// does not resolve for a dependency. This points at the symlink directory rather than at
// Core/Requests/Responses on purpose: reaching the same header by two different paths makes
// clang treat it as two files and fail with "duplicate interface definition".
let coreFromSibling: [CSetting] = [
    .headerSearchPath("../GCDWebServer/include/GCDWebServers")
]

let package = Package(
    name: "WebServerKit",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .tvOS(.v15)
    ],
    products: [
        // Everything, matching the GCDWebServers framework.
        .library(name: "GCDWebServers", targets: ["GCDWebServers", "GCDWebDAVServer", "GCDWebUploader"]),
        // The individual pieces, matching the CocoaPods subspecs, for anyone who does not
        // want to link libxml2 or ship the uploader's web assets.
        .library(name: "GCDWebServerCore", targets: ["GCDWebServers"]),
        .library(name: "GCDWebDAVServer", targets: ["GCDWebDAVServer"]),
        .library(name: "GCDWebUploader", targets: ["GCDWebUploader"])
    ],
    targets: [
        .target(
            name: "GCDWebServers",
            path: "Sources/GCDWebServer",
            publicHeadersPath: "include",
            cSettings: coreSources,
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedFramework("CFNetwork"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .target(
            name: "GCDWebDAVServer",
            dependencies: ["GCDWebServers"],
            path: "Sources/GCDWebDAVServer",
            publicHeadersPath: ".",
            cSettings: coreFromSibling,
            linkerSettings: [
                // No header search path is needed for libxml2: every Apple SDK exposes the
                // headers at usr/include/libxml, so <libxml/parser.h> resolves unaided. That
                // matters — reaching them any other way would need unsafeFlags, and a package
                // using those cannot be depended upon by version.
                .linkedLibrary("xml2")
            ]
        ),
        .target(
            name: "GCDWebUploader",
            dependencies: ["GCDWebServers"],
            path: "Sources/GCDWebUploader",
            resources: [
                .copy("GCDWebUploader.bundle")
            ],
            // A hand-written module.modulemap lives here because the public headers sit next
            // to GCDWebUploader.bundle, and SwiftPM rejects an umbrella header that has
            // sibling directories. Mapping them from include/ keeps the bundle where the
            // Xcode project and the podspec already expect it.
            publicHeadersPath: "include",
            cSettings: coreFromSibling
        )
    ]
)
