// swift-tools-version: 5.9
import PackageDescription

// See docs/architecture/chunks/project-structure.md for the full rationale
// behind every decision in this manifest (tools-version, target graph,
// why there's a .library product per module, etc).

let package = Package(
    name: "MacGriddle",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "MacGriddleCore", targets: ["MacGriddleCore"]),
        .library(name: "GridEngine", targets: ["GridEngine"]),
        .library(name: "WindowControl", targets: ["WindowControl"]),
        .library(name: "Overlay", targets: ["Overlay"]),
        .library(name: "Permissions", targets: ["Permissions"]),
        .library(name: "Preferences", targets: ["Preferences"]),
        .library(name: "StatusBar", targets: ["StatusBar"]),
        .library(name: "Input", targets: ["Input"]),
        .executable(name: "MacGriddle", targets: ["MacGriddle"])
    ],
    targets: [
        // MARK: - MacGriddleCore
        // Shared protocols/types (docs/architecture/chunks/core-contracts.md).
        // No dependencies. Every other target may depend on this; this must
        // never depend on them.
        .target(
            name: "MacGriddleCore",
            dependencies: []
        ),

        // MARK: - GridEngine
        // Pure grid math (docs/architecture/chunks/grid-engine.md). Deliberately
        // dependency-free, including MacGriddleCore — GridConfiguration/GridCell
        // live here, not in Core, so this target never needs to import anything
        // beyond CoreGraphics/Foundation. No AppKit import anywhere in this target.
        .target(
            name: "GridEngine",
            dependencies: []
        ),
        .testTarget(
            name: "GridEngineTests",
            dependencies: ["GridEngine"]
        ),

        // MARK: - WindowControl
        // AX window lookup/read/write frame (docs/architecture/chunks/window-control-and-coordinates.md).
        .target(
            name: "WindowControl",
            dependencies: ["MacGriddleCore"]
        ),

        // MARK: - Overlay
        // Per-screen grid overlay NSWindows + rendering (docs/architecture/chunks/overlay-rendering.md).
        .target(
            name: "Overlay",
            dependencies: ["MacGriddleCore", "GridEngine"]
        ),

        // MARK: - Permissions
        // Accessibility + Input Monitoring check/request/observe (docs/architecture/chunks/permissions-model.md).
        .target(
            name: "Permissions",
            dependencies: ["MacGriddleCore"]
        ),

        // MARK: - Preferences
        // SwiftUI settings window + UserDefaults-backed store (docs/architecture/chunks/preferences-ui.md).
        .target(
            name: "Preferences",
            dependencies: ["MacGriddleCore"]
        ),

        // MARK: - StatusBar
        // NSStatusItem + menu (docs/architecture/chunks/statusbar-menu.md).
        .target(
            name: "StatusBar",
            dependencies: ["MacGriddleCore", "Preferences"]
        ),

        // MARK: - Input
        // CGEventTap + gesture state machine (docs/architecture/chunks/input-engine-and-state-machine.md).
        // Orchestrates WindowControl, Overlay, and Permissions during a live gesture.
        .target(
            name: "Input",
            dependencies: [
                "MacGriddleCore",
                "GridEngine",
                "WindowControl",
                "Overlay",
                "Permissions"
            ]
        ),

        // MARK: - MacGriddle (executable)
        // App entry point / composition root (docs/architecture/chunks/app-shell-and-lifecycle.md).
        // Depends on every other module target so it can wire them together at launch.
        .executableTarget(
            name: "MacGriddle",
            dependencies: [
                "MacGriddleCore",
                "GridEngine",
                "WindowControl",
                "Overlay",
                "Permissions",
                "Preferences",
                "StatusBar",
                "Input"
            ]
        )
    ]
)
