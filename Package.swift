// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "NetSocket",
  platforms: [
    .macOS(.v13),
    .iOS(.v16),
    .tvOS(.v16),
    .visionOS(.v1),
  ],
  products: [
    .library(name: "NetSocket", targets: ["NetSocket"]),
  ],
  targets: [
    .target(name: "NetSocket"),
    .testTarget(name: "NetSocketTests", dependencies: ["NetSocket"]),
  ]
)
