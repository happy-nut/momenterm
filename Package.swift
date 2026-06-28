// swift-tools-version:5.4

import PackageDescription

let package = Package(
    name: "momenterm",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .executable(name: "Momenterm", targets: ["Momenterm"])
    ],
    targets: [
        .target(name: "Momenterm")
    ]
)
