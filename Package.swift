// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "WearableRecorder",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [
    .library(name: "DeviceProtocol", targets: ["DeviceProtocol"]),
    .library(name: "BLEClient", targets: ["BLEClient"]),
    .library(name: "RecordingFeature", targets: ["RecordingFeature"]),
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.17.0"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.6.0"),
    .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
  ],
  targets: [
    // Pure Swift, no Apple frameworks: framing, checksums, bit-packed config.
    .target(name: "DeviceProtocol"),
    .testTarget(name: "DeviceProtocolTests", dependencies: ["DeviceProtocol"]),

    // CoreBluetooth behind an async/AsyncStream dependency, plus a simulated peripheral.
    .target(
      name: "BLEClient",
      dependencies: [
        "DeviceProtocol",
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "DependenciesMacros", package: "swift-dependencies"),
      ]
    ),

    // TCA feature: scan, connect, record, survive link loss and relaunch.
    .target(
      name: "RecordingFeature",
      dependencies: [
        "BLEClient",
        "DeviceProtocol",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    .testTarget(
      name: "RecordingFeatureTests",
      dependencies: [
        "RecordingFeature",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
      ],
      exclude: ["__Snapshots__"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
