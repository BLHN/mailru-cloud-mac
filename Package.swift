// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CloudMail",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CloudMail",
            path: "Sources/CloudMail",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ],
    swiftLanguageVersions: [.v5]
)
