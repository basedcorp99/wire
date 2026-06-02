// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "wire",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "wire", targets: ["wire"])
    ],
    targets: [
        .executableTarget(
            name: "wire",
            path: "Sources"
        )
    ]
)
