import Foundation

/// Where a shortcut was found, which also says how far to trust it.
public enum ShortcutSource: String, Codable, Sendable, CaseIterable {
    /// Keyboard settings: Spotlight, screenshots, Mission Control and the rest.
    case macOS
    /// Fixed macOS shortcuts that Keyboard settings doesn't list (⌘Tab, Lock Screen).
    case builtIn
    /// Services menu items given a shortcut.
    case services
    /// App Shortcuts set in Keyboard settings: menu items renamed to new keys.
    case menuOverride
    /// Read from an app's own settings file.
    case appSettings
    /// Sent by the app itself while it runs (our own apps).
    case appReport
    /// The frontmost app's menu bar, read through Accessibility.
    case appMenus
    /// An app's usual default that it never writes down (`KnownDefaults`).
    case knownDefault

    public var title: String {
        switch self {
        case .macOS: "Keyboard settings"
        case .builtIn: "Built into macOS"
        case .services: "Services"
        case .menuOverride: "App Shortcuts"
        case .appSettings: "Found in the app's settings"
        case .appReport: "Reported by the app"
        case .appMenus: "App menus"
        case .knownDefault: "The app's usual default"
        }
    }

    /// Whether the shortcut works everywhere rather than only inside one app.
    /// Whether it belongs to an app that must be running for the keys to work.
    public var needsApp: Bool { self == .appSettings || self == .appReport || self == .knownDefault }

    public var isGlobal: Bool {
        switch self {
        case .macOS, .builtIn, .services, .appSettings, .appReport, .knownDefault: true
        case .menuOverride, .appMenus: false
        }
    }
}

/// One shortcut, from any source.
public struct ShortcutEntry: Identifiable, Hashable, Sendable {
    /// Stable across scans, so hiding one sticks.
    public var id: String
    /// The app's bundle id, `com.apple.macOS` for macOS itself, or `com.apple.services`.
    public var ownerID: String
    public var ownerName: String
    public var title: String
    /// A heading within the owner ("Screenshots", "Mission Control").
    public var category: String?
    public var combo: KeyCombo
    public var enabled: Bool
    public var source: ShortcutSource
    /// Extra detail for the inspector: the settings key it came from, a caveat.
    public var detail: String?
    /// Where an `.appMenus` entry sits ("File › Export").
    public var menuPath: String?
    /// How the keys are used, when an app's report says: "hold", "doubleTap" or "toggle".
    /// nil is an ordinary press.
    public var gesture: String?
    /// The app said it can take a new shortcut for this one from ShortcutsLens.
    public var changeable: Bool

    public init(id: String, ownerID: String, ownerName: String, title: String, category: String? = nil,
                combo: KeyCombo, enabled: Bool = true, source: ShortcutSource, detail: String? = nil, menuPath: String? = nil,
                gesture: String? = nil, changeable: Bool = false) {
        self.id = id
        self.ownerID = ownerID
        self.ownerName = ownerName
        self.title = title
        self.category = category
        self.combo = combo
        self.enabled = enabled
        self.source = source
        self.detail = detail
        self.menuPath = menuPath
        self.gesture = gesture
        self.changeable = changeable
    }

    /// "Hold", "Double-tap", "Press to start and stop", or nil for a press.
    public var gestureTitle: String? {
        switch gesture {
        case nil: nil
        case "hold": "Hold"
        case "doubleTap": "Double-tap"
        case "toggle": "Press to start and stop"
        case let other?: other
        }
    }

    public static let macOSOwner = "com.apple.macOS"
    public static let servicesOwner = "com.apple.services"
    public static let allAppsOwner = "NSGlobalDomain"

    public var isGlobal: Bool { source.isGlobal }

    /// Case- and accent-insensitive match on the title, owner, category, keys and spoken keys.
    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let haystack = [title, ownerName, category ?? "", combo.display, combo.spoken, menuPath ?? ""].joined(separator: " ")
        return q.split(separator: " ").allSatisfy { term in
            haystack.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                // Typing "⌘⇧4" finds ⇧⌘4: glyphs match in any order.
                || Self.glyphMatch(String(term), combo)
        }
    }

    private static func glyphMatch(_ term: String, _ combo: KeyCombo) -> Bool {
        let glyphs: [Character: Modifiers] = ["⌃": .control, "⌥": .option, "⇧": .shift, "⌘": .command, "🌐": .function]
        var mods: Modifiers = []
        var rest = ""
        for ch in term {
            if let m = glyphs[ch] { mods.insert(m) } else { rest.append(ch) }
        }
        guard !mods.isEmpty, combo.modifiers.isSuperset(of: mods) else { return false }
        guard !rest.isEmpty else { return true }
        guard let keyCode = combo.keyCode else { return false }
        return KeyNames.name(for: keyCode).caseInsensitiveCompare(rest) == .orderedSame
    }
}

/// Shortcuts that share keys.
public enum Conflicts {
    /// Every key combination that two or more enabled, system-wide shortcuts claim. Within
    /// one app it takes two exact entries (macOS's own, or an app's report) used the same way:
    /// a settings file often stores one shortcut in two places, under two names, and an app
    /// that tells holding a key from double-tapping it keeps the two apart itself.
    public static func find(in entries: [ShortcutEntry]) -> [KeyCombo: [ShortcutEntry]] {
        var byCombo: [KeyCombo: [ShortcutEntry]] = [:]
        for entry in entries where entry.enabled && entry.isGlobal {
            byCombo[entry.combo, default: []].append(entry)
        }
        var found: [KeyCombo: [ShortcutEntry]] = [:]
        for (combo, list) in byCombo {
            // Entries that collide with at least one other on this combo.
            let clashing = list.filter { entry in list.contains { collide(entry, $0) } }
            if !clashing.isEmpty { found[combo] = clashing }
        }
        return found
    }

    /// The other entries a shortcut collides with.
    public static func partners(of entry: ShortcutEntry, in conflicts: [KeyCombo: [ShortcutEntry]]) -> [ShortcutEntry] {
        guard entry.enabled, entry.isGlobal else { return [] }
        return (conflicts[entry.combo] ?? []).filter { collide(entry, $0) }
    }

    /// Two entries on the same combo. Different apps always collide, since both hear the
    /// keys. Within one app, only two different exact shortcuts used the same way do.
    static func collide(_ a: ShortcutEntry, _ b: ShortcutEntry) -> Bool {
        guard a.id != b.id else { return false }
        if a.ownerID != b.ownerID { return true }
        return a.source != .appSettings && b.source != .appSettings && a.gesture == b.gesture
            && a.title.lowercased() != b.title.lowercased()
    }
}
