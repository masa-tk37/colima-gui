// swift-tools-version: 6.4

import PackageDescription

let package = Package(
  name: "ColimaKit",
  defaultLocalization: "en",
  platforms: [
    .macOS("27.2")
  ],
  products: [
    .library(name: "ColimaCore", targets: ["ColimaCore"]),
    .library(name: "ColimaAdapters", targets: ["ColimaAdapters"]),
    .library(name: "ColimaProcess", targets: ["ColimaProcess"]),
    .library(name: "ColimaUI", targets: ["ColimaUI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.37.0")
  ],
  targets: [
    .target(
      name: "ColimaCore",
      resources: [.process("Resources")],
      swiftSettings: [
        .enableUpcomingFeature("ApproachableConcurrency")
      ],
    ),
    .target(
      name: "ColimaProcess",
      dependencies: ["ColimaCore"],
      swiftSettings: [
        .enableUpcomingFeature("ApproachableConcurrency")
      ],
    ),
    .target(
      name: "ColimaAdapters",
      dependencies: [
        "ColimaCore",
        "ColimaProcess",
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
      ],
      resources: [.process("Resources")],
      swiftSettings: [
        .enableUpcomingFeature("ApproachableConcurrency")
      ],
    ),
    .target(
      name: "ColimaUI",
      dependencies: ["ColimaCore"],
      resources: [.process("Resources")],
      swiftSettings: [
        .enableUpcomingFeature("ApproachableConcurrency")
      ],
    ),
    .testTarget(
      name: "ColimaCoreTests",
      dependencies: ["ColimaCore"],
      resources: [
        .copy("Fixtures")
      ],
      swiftSettings: [
        .enableUpcomingFeature("ApproachableConcurrency")
      ],
    ),
    .testTarget(
      name: "ColimaUITests",
      dependencies: ["ColimaUI", "ColimaCore"],
      swiftSettings: [
        .enableUpcomingFeature("ApproachableConcurrency")
      ],
    ),
    .testTarget(
      name: "ColimaAdaptersTests",
      dependencies: ["ColimaAdapters", "ColimaCore", "ColimaProcess"],
      resources: [
        .copy("Fixtures")
      ],
      swiftSettings: [
        .enableUpcomingFeature("ApproachableConcurrency")
      ],
    ),
  ],
  swiftLanguageModes: [.v6]
)
