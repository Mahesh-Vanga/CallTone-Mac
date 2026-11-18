// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CallTone",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CallTone", targets: ["CallTone"])
    ],
    targets: [
        .executableTarget(
            name: "CallTone",
            path: "Sources/CallTone",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .testTarget(
            name: "CallToneTests",
            dependencies: ["CallTone"],
            path: "Tests/CallToneTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
