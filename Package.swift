// swift-tools-version: 6.0
//
// ADTPro - Apple Disk Transfer ProDOS
// Swift host implementation.
//
// Licensed under the GNU General Public License, version 2 or later.

import PackageDescription

let package = Package(
    name: "ADTPro",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "DiskImage", targets: ["DiskImage"]),
        .library(name: "ADTProCore", targets: ["ADTProCore"]),
        .executable(name: "adtpro", targets: ["adtpro"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // Apple II disk image formats: sector orders, 2IMG, nibble images,
        // ProDOS volume creation and file placement.
        .target(name: "DiskImage"),

        // The ADTPro host: wire protocol, transports, bootstrapping, virtual drives.
        .target(
            name: "ADTProCore",
            dependencies: ["DiskImage"],
            resources: [.copy("Resources/Payloads")]
        ),

        // Command line host, usable on macOS and Linux.
        .executableTarget(
            name: "adtpro",
            dependencies: [
                "ADTProCore",
                "DiskImage",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        .testTarget(name: "DiskImageTests", dependencies: ["DiskImage"]),
        .testTarget(name: "ADTProCoreTests", dependencies: ["ADTProCore", "DiskImage"]),
    ]
)
