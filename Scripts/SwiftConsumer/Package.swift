// swift-tools-version:6.0

// The package as an app consumes it, in Swift 6 language mode. Run-Tests.sh builds this
// with both generators and runs it: an executable has to LINK (a library-only `swift build`
// never does, so the resource-bundle accessor — named differently by SwiftPM and by Xcode —
// can go missing without a build ever failing), and a handler closure registered from
// main-actor code only shows whether Swift let it be called on a connection queue when a
// request actually arrives. Kept outside the main manifest so the library itself stays at
// swift-tools-version 5.9; only this check needs a Swift 6 toolchain.
import PackageDescription

let package = Package(
    name: "SwiftConsumer",
    platforms: [.macOS(.v12)],
    dependencies: [
        .package(name: "WebServerKit", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "SwiftConsumer",
            dependencies: [
                .product(name: "WebServerKit", package: "WebServerKit")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
