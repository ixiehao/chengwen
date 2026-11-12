// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "ChengWen",
    platforms: [.macOS(.v12)],
    products: [.executable(name: "ChengWen", targets: ["ChengWen"])],
    targets: [
        .executableTarget(name: "ChengWen", resources: [.copy("Resources")]),
        .testTarget(name: "ChengWenTests", dependencies: ["ChengWen"], path: "Tests/ChengWenTests"),
    ]
)
