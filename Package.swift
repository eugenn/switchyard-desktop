// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "switchyard-desktop",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.5.0")
    ],
    targets: [
        .target(
            name: "SwitchyardDesktopKit",
            dependencies: [
                .product(name: "TOMLKit", package: "TOMLKit")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "SwitchyardDesktopApp",
            dependencies: [
                "SwitchyardDesktopKit"
            ]
        ),
        .testTarget(
            name: "SwitchyardDesktopKitTests",
            dependencies: [
                "SwitchyardDesktopKit",
                .product(name: "TOMLKit", package: "TOMLKit")
            ]
        ),
        .testTarget(
            name: "SwitchyardDesktopAppTests",
            dependencies: [
                "SwitchyardDesktopApp"
            ]
        )
    ]
)
