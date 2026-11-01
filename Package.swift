// swift-tools-version: 6.2
import PackageDescription

// ShortcutsLensKit holds the parts that don't need AppKit: key combos, the macOS shortcut
// table, the settings scanner, conflicts and the keyboard map, so `swift test` covers them.
// The app is built by build_app.sh.
let package = Package(
    name: "ShortcutsLens",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "ShortcutsLensKit"),
        .executableTarget(name: "ShortcutsLens", dependencies: ["ShortcutsLensKit"]),
        .testTarget(name: "ShortcutsLensKitTests", dependencies: ["ShortcutsLensKit"]),
    ]
)
