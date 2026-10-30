// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DeskAnchor",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DeskAnchorApp", targets: ["DeskAnchorApp"]),
        .executable(name: "deskanchor", targets: ["DeskAnchorCLI"]),
        .library(name: "WorkspaceCore", targets: ["WorkspaceCore"])
    ],
    targets: [
        .target(name: "WorkspaceCore"),
        .executableTarget(name: "DeskAnchorApp", dependencies: ["WorkspaceCore"], linkerSettings: [
            .linkedFramework("AppKit"), .linkedFramework("ApplicationServices"),
            .linkedFramework("Carbon"), .linkedFramework("ServiceManagement")
        ]),
        .executableTarget(name: "DeskAnchorCLI", dependencies: ["WorkspaceCore"]),
        .testTarget(name: "WorkspaceCoreTests", dependencies: ["WorkspaceCore"])
    ]
)
