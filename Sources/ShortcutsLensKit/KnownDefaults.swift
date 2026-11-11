import Foundation

/// Global shortcuts some apps use out of the box but never write down until you change them,
/// so no settings scan can find them. Listed only when the app is installed and ShortcutsLens
/// found nothing else for it (no settings, no report), since either of those is better.
///
/// Only defaults the developer documents, or that were seen holding the keys, belong here: a
/// wrong one would call a free shortcut taken.
public enum KnownDefaults {
    public struct Shortcut: Sendable {
        public let id: String
        public let title: String
        public let keyCode: Int
        public let modifiers: Modifiers
    }

    public struct App: Sendable {
        public let bundleID: String
        /// Processes that hold the keys while the app itself is closed (a capture helper or
        /// login item), by bundle id.
        public let helperIDs: [String]
        /// Where in the app the shortcut is changed, for the inspector.
        public let whereToChange: String
        public let shortcuts: [Shortcut]
    }

    // Key codes (US positions): A 0, S 1, G 5, Z 6, X 7, C 8, V 9, R 15, 2 19, = 24, - 27, O 31,
    // P 35, L 37, K 40, \ 42, / 44, Tab 48, Space 49, Delete 51, Esc 53.
    private static let ctrlShift: Modifiers = [.control, .shift]

    /// Checked 2026-11-11 against each developer's own documentation (or source code).
    public static var apps: [App] {
        [
            // techsmith.com/learn/tutorials/snagit/snagit-hotkeys + the printable Mac shortcuts guide.
            // The capture helper registers them, so they work while Snagit itself is closed.
            App(bundleID: "com.TechSmith.Snagit", helperIDs: ["com.techsmith.snagit.capturehelper"],
                whereToChange: "Snagit's capture presets or Settings › Keyboard",
                shortcuts: [
                    .init(id: "capture", title: "Global Capture", keyCode: 8, modifiers: ctrlShift),
                    .init(id: "allinone", title: "All-in-One Capture", keyCode: 31, modifiers: ctrlShift),
                    .init(id: "image", title: "Image Capture", keyCode: 1, modifiers: ctrlShift),
                    .init(id: "video", title: "Video Capture", keyCode: 9, modifiers: ctrlShift),
                    .init(id: "repeat", title: "Repeat Last Capture", keyCode: 15, modifiers: ctrlShift),
                ]),
            // support.1password.com/keyboard-shortcuts: Quick Access moved to ⌥⌘\ on macOS 27 (8.12.38).
            App(bundleID: "com.1password.1password", helperIDs: [],
                whereToChange: "1Password › Settings › General",
                shortcuts: [
                    ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
                        ? .init(id: "quickaccess", title: "Show Quick Access", keyCode: 42, modifiers: [.option, .command])
                        : .init(id: "quickaccess", title: "Show Quick Access", keyCode: 49, modifiers: [.shift, .command]),
                    .init(id: "lock", title: "Lock 1Password", keyCode: 37, modifiers: [.shift, .command]),
                    .init(id: "autofill", title: "Autofill", keyCode: 42, modifiers: [.command]),
                ]),
            // tapbots.com/pastebot/help: the only shortcut on by default.
            App(bundleID: "com.tapbots.Pastebot3Mac", helperIDs: [], whereToChange: "Pastebot › Settings",
                shortcuts: [.init(id: "quickpaste", title: "Show Quick Paste", keyCode: 9, modifiers: [.shift, .command])]),
            // textsniper.app
            App(bundleID: "com.valerijs.boguckis.store.TextSniper", helperIDs: [], whereToChange: "TextSniper › Settings",
                shortcuts: [.init(id: "capture", title: "Capture Text", keyCode: 19, modifiers: [.shift, .command])]),
            // textexpander.com/learn/using/searching-snippets/inline-search
            App(bundleID: "com.smileonmymac.textexpander", helperIDs: [], whereToChange: "TextExpander › Settings › Keyboard",
                shortcuts: [.init(id: "inlinesearch", title: "Inline Search", keyCode: 44, modifiers: [.command])]),
            // github.com/FuzzyIdeas/Clop: README and DEFAULT_GLOBAL_KEYS (⌃⇧ plus a key).
            App(bundleID: "com.lowtechguys.Clop", helperIDs: [], whereToChange: "Clop › Settings › Keyboard shortcuts",
                shortcuts: [
                    .init(id: "optimise", title: "Optimize the clipboard", keyCode: 8, modifiers: ctrlShift),
                    .init(id: "aggressive", title: "Optimize aggressively", keyCode: 0, modifiers: ctrlShift),
                    .init(id: "downscale", title: "Downscale", keyCode: 27, modifiers: ctrlShift),
                    .init(id: "bringback", title: "Bring back last removed result", keyCode: 24, modifiers: ctrlShift),
                    .init(id: "remove", title: "Remove latest result", keyCode: 51, modifiers: ctrlShift),
                    .init(id: "quicklook", title: "Quick Look", keyCode: 49, modifiers: ctrlShift),
                    .init(id: "restore", title: "Restore original", keyCode: 6, modifiers: ctrlShift),
                    .init(id: "pause", title: "Pause automatic optimizing", keyCode: 35, modifiers: ctrlShift),
                    .init(id: "speed", title: "Change playback speed", keyCode: 7, modifiers: ctrlShift),
                    .init(id: "rename", title: "Rename result", keyCode: 15, modifiers: ctrlShift),
                    .init(id: "crop", title: "Crop", keyCode: 40, modifiers: ctrlShift),
                    .init(id: "dismiss", title: "Stop all and dismiss results", keyCode: 53, modifiers: ctrlShift),
                ]),
            // presentifyapp.com/presentify-keyboard-shortcuts ("the shortcuts below are the defaults").
            App(bundleID: "com.rampatra.presentify", helperIDs: [], whereToChange: "Presentify › Settings › Shortcuts",
                shortcuts: [
                    .init(id: "annotate", title: "Annotate Screen", keyCode: 0, modifiers: [.control]),
                    .init(id: "annotatebare", title: "Annotate Without Controls", keyCode: 0, modifiers: [.control, .option]),
                    .init(id: "highlight", title: "Highlight Cursor", keyCode: 1, modifiers: [.control]),
                    .init(id: "spotlight", title: "Spotlight Cursor", keyCode: 37, modifiers: [.control]),
                    .init(id: "zoom", title: "Zoom Cursor", keyCode: 6, modifiers: [.control]),
                ]),
            // support.grammarly.com/hc/en-us/articles/24059143083277
            App(bundleID: "com.grammarly.ProjectLlama", helperIDs: [], whereToChange: "Grammarly › Settings",
                shortcuts: [.init(id: "assistant", title: "Open the Grammarly assistant", keyCode: 5, modifiers: [.control, .shift, .command])]),
            // github.com/altic-dev/FluidVoice SettingsStore. Its dictation key is the right ⌥ alone,
            // which a combo can't tell from the left one, so it isn't listed.
            App(bundleID: "com.FluidApp.app", helperIDs: [], whereToChange: "FluidVoice › Settings",
                shortcuts: [.init(id: "editmode", title: "Edit Mode", keyCode: 15, modifiers: [.option])]),
            // funk-isoft.com/display-maid.html
            App(bundleID: "com.Funk-iSoft.Display-Maid", helperIDs: [], whereToChange: "Display Maid › Settings",
                shortcuts: [.init(id: "profiles", title: "Quick profile selector", keyCode: 48, modifiers: [.control, .command])]),
        ]
    }

    public static func app(_ bundleID: String) -> App? { apps.first { $0.bundleID == bundleID } }

    /// Bundle ids of the listed apps.
    public static let bundleIDs: Set<String> = Set(apps.map(\.bundleID))

    /// Bundle ids of processes that hold this owner's default shortcuts.
    public static func helperIDs(for ownerID: String) -> [String] {
        bundleIDs.contains(ownerID) ? app(ownerID)?.helperIDs ?? [] : []
    }

    public static func entries(for app: App, appName: String) -> [ShortcutEntry] {
        app.shortcuts.map { s in
            ShortcutEntry(id: "default|\(app.bundleID)|\(s.id)", ownerID: app.bundleID, ownerName: appName, title: s.title,
                          combo: KeyCombo(keyCode: s.keyCode, modifiers: s.modifiers), source: .knownDefault,
                          detail: "\(appName)'s usual default. \(appName) doesn't save it anywhere ShortcutsLens can read, so if you've changed it in \(app.whereToChange), it may use other keys now. Hide this one if so.")
        }
    }
}
