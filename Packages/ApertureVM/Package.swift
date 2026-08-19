// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ApertureVM",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ApertureVM", targets: ["ApertureVM"]),
        .executable(name: "aperture-vm", targets: ["ApertureVMCLI"]),
    ],
    targets: [
        .target(
            name: "ApertureVM",
            linkerSettings: [.linkedFramework("Virtualization")]
        ),
        .executableTarget(
            name: "ApertureVMCLI",
            dependencies: ["ApertureVM"],
            linkerSettings: [.linkedFramework("Virtualization")]
        ),
    ]
)
