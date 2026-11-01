// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "omux",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "omux",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/omux",
            // build.sh embeds Sparkle.framework in the app bundle; the binary finds it there.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(name: "omux-session-relay", path: "Sources/SessionRelay"),
        .testTarget(name: "omuxTests", dependencies: ["omux"]),
    ],
    swiftLanguageModes: [.v5]
)
