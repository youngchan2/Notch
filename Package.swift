// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Notchwave",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Notchwave", targets: ["Notchwave"])],
    targets: [.executableTarget(name: "Notchwave")]
)
