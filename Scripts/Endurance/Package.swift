// swift-tools-version:5.9
import PackageDescription

// A local test executable, deliberately outside the library's published products.
let package = Package(
    name: "Endurance",
    platforms: [.macOS(.v12)],
    dependencies: [.package(name: "WebServerKit", path: "../..")],
    targets: [
        .executableTarget(
            name: "EnduranceHost",
            dependencies: [.product(name: "WebServerKit", package: "WebServerKit")],
            cSettings: [.unsafeFlags(["-fobjc-arc", "-fmodules"])],
            linkerSettings: [.linkedFramework("Foundation")]
        )
    ]
)
