// swift-tools-version:5.4

import PackageDescription

let package = Package(
    name: "momenterm",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .executable(name: "Momenterm", targets: ["Momenterm"]),
        .executable(name: "MomentermCLI", targets: ["MomentermCLI"])
    ],
    targets: [
        .target(
            name: "Momenterm",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("WebKit")
            ]
        ),
        // Control-socket client. Shares the pure wire protocol with the app via a
        // symlink to Sources/Momenterm/MomentermCommandProtocol.swift so there is
        // exactly one source of truth for encode/decode.
        .executableTarget(
            name: "MomentermCLI"
        )
    ]
)
