// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Pano",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Pano", targets: ["Pano"])],
    targets: [.executableTarget(name: "Pano", path: "Sources/Pano")],
    swiftLanguageVersions: [.v5]
)
