// swift-tools-version: 6.1
import PackageDescription

// a2ui-check: checks an Extension's A2UI messages against dense's catalog, without building
// dense. Run it with check.sh, which builds it with the app's pinned versions.
let package = Package(
    name: "A2UICheck",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/a2ui-project/a2ui", exact: "0.12.0+swift"),
    ],
    targets: [
        .executableTarget(
            name: "a2ui-check",
            dependencies: [
                .product(name: "A2UISwiftCore", package: "a2ui"),
                .product(name: "BasicCatalog", package: "a2ui"),
            ]
        ),
    ]
)
