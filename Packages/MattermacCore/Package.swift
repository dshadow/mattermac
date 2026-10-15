// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "MattermacCore",
  platforms: [.macOS("27.0")],
  products: [.library(name: "MattermacCore", targets: ["MattermacCore"])],
  targets: [
    .target(name: "MattermacCore"),
    .testTarget(name: "MattermacCoreTests", dependencies: ["MattermacCore"]),
  ],
  swiftLanguageModes: [.v6]
)
