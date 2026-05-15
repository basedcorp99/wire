// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SimpleTranscriber",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SimpleTranscriber", targets: ["SimpleTranscriber"])
    ],
    targets: [
        .executableTarget(
            name: "SimpleTranscriber",
            path: "Sources"
        )
    ]
)
