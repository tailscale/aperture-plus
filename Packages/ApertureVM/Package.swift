// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ApertureVM",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ApertureVM", targets: ["ApertureVM"]),
    ],
    targets: [
        .target(
            name: "ApertureVM",
            linkerSettings: [.linkedFramework("Virtualization")]
        ),
    ]
)
