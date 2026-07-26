// swift-tools-version:5.9

import PackageDescription

// The public headers are spread across Core/, Requests/ and Responses/, and they import each
// other by bare filename as the fallback arm of `#if __has_include(<Serve/…>)`. Naming the
// core module Serve — the same name the framework uses — makes the angle-bracket arm win,
// which resolves through Sources/Serve/include/Serve (a directory of symlinks to the real
// headers, deliberately excluding SRVPrivate.h). Without that the module cannot be built by a
// Swift consumer at all: the umbrella would drag in the private header, which imports a dozen
// others it cannot find.
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
    .headerSearchPath("../Serve/include/Serve")
]

let package = Package(
    name: "Serve",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .tvOS(.v15)
    ],
    products: [
        // Everything, matching the Serve framework.
        .library(name: "Serve", targets: ["Serve", "ServeWebDAV", "ServeUploader"]),
        // The individual pieces, matching the CocoaPods subspecs, for anyone who does not
        // want to link libxml2 or ship the uploader's web assets.
        .library(name: "ServeCore", targets: ["Serve"]),
        .library(name: "ServeWebDAV", targets: ["ServeWebDAV"]),
        .library(name: "ServeUploader", targets: ["ServeUploader"])
    ],
    targets: [
        .target(
            name: "Serve",
            path: "Sources/Serve",
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
            name: "ServeWebDAV",
            dependencies: ["Serve"],
            path: "Sources/ServeWebDAV",
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
            name: "ServeUploader",
            dependencies: ["Serve"],
            path: "Sources/ServeUploader",
            resources: [
                .copy("SRVUploader.bundle")
            ],
            // A hand-written module.modulemap lives here because the public headers sit next
            // to SRVUploader.bundle, and SwiftPM rejects an umbrella header that has sibling
            // directories. Mapping them from include/ keeps the bundle where the Xcode project
            // and the podspec already expect it.
            publicHeadersPath: "include",
            cSettings: coreFromSibling
        ),
        // Not a product — a link check. `swift build` on a library target compiles but never
        // links, so an undefined symbol survives it: the SwiftPM resource accessor is named
        // after the *target* (ServeUploader_SWIFTPM_MODULE_BUNDLE), and a rename of the
        // classes silently broke it while every build stayed green. Linking an executable
        // is what surfaces that.
        .executableTarget(
            name: "ServeLinkCheck",
            dependencies: ["Serve", "ServeWebDAV", "ServeUploader"],
            path: "Sources/ServeLinkCheck"
        )
    ]
)
