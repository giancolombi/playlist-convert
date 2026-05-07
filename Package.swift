// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PlaylistConvert",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "PlaylistConvert",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/PlaylistConvert",
            exclude: ["Resources/Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/PlaylistConvert/Resources/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "PlaylistConvertTests",
            dependencies: ["PlaylistConvert"],
            path: "Tests/PlaylistConvertTests"
        )
    ]
)
