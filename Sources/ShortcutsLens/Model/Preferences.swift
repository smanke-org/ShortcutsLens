import AppKit
import Observation
import ShortcutsLensKit

/// ShortcutsLens's own settings, in UserDefaults. Each change re-registers what it needs
/// and tells settings sync.
@Observable
@MainActor
final class Preferences {
    static let shared = Preferences()

    enum Keys {
        static let quickViewHotKey = "quickViewHotKey"
        static let holdCommand = "holdCommandForQuickView"
        static let quickViewStartsOn = "quickViewStartsOn"
        static let showDisabled = "showDisabled"
        static let scanSandboxed = "scanSandboxedApps"
        static let hiddenEntries = "hiddenEntries"
        static let hiddenApps = "hiddenApps"
        static let confirmQuit = "confirmQuit"
    }

    /// The synced ones (settings sync adds presence, appearance and updates).
    static let keys = [Keys.quickViewHotKey, Keys.holdCommand, Keys.quickViewStartsOn, Keys.showDisabled, Keys.scanSandboxed,
                       Keys.hiddenEntries, Keys.hiddenApps, Keys.confirmQuit]

    /// ⌃⌥⌘/, the ? key. Three modifiers keep it out of the way of app menus.
    static let defaultHotKey = KeyCombo(keyCode: 44, modifiers: [.control, .option, .command])
    /// 1.0.0's default, which ClickLens also uses.
    private static let oldDefaultHotKey = KeyCombo(keyCode: 40, modifiers: [.control, .option, .command])

    enum StartPage: String, CaseIterable, Identifiable {
        case frontmostApp, systemWide
        var id: String { rawValue }
        var title: String {
            switch self {
            case .frontmostApp: "The app in front"
            case .systemWide: "System-wide shortcuts"
            }
        }
    }

    var quickViewHotKey: KeyCombo? { didSet { save(Keys.quickViewHotKey, encode(quickViewHotKey)); HotKeyCenter.shared.apply() } }
    var holdCommand: Bool { didSet { save(Keys.holdCommand, holdCommand); HotKeyCenter.shared.apply() } }
    var quickViewStartsOn: StartPage { didSet { save(Keys.quickViewStartsOn, quickViewStartsOn.rawValue) } }
    var showDisabled: Bool { didSet { save(Keys.showDisabled, showDisabled) } }
    var scanSandboxed: Bool { didSet { save(Keys.scanSandboxed, scanSandboxed); ShortcutStore.shared.refresh() } }
    var hiddenEntries: Set<String> { didSet { save(Keys.hiddenEntries, hiddenEntries.sorted()) } }
    var hiddenApps: Set<String> { didSet { save(Keys.hiddenApps, hiddenApps.sorted()) } }
    var confirmQuit: Bool { didSet { save(Keys.confirmQuit, confirmQuit) } }

    @ObservationIgnored private var loading = false
    private var defaults: UserDefaults { Self.store }

    /// UserDefaults.standard, except in an agent CLI test copy (a Debug build run with
    /// APP_STORE), which keeps its settings in a suite of its own and never touches the
    /// installed app's.
    static let store: UserDefaults = {
        #if DEBUG
        if AgentSocket.isTestRun, let suite = UserDefaults(suiteName: testSuite) { return suite }
        #endif
        return .standard
    }()

    static let testSuite = "com.smanke.ShortcutsLens.agenttest"

    private init() {
        let d = Self.store
        d.register(defaults: [Keys.holdCommand: false, Keys.showDisabled: true, Keys.scanSandboxed: false, Keys.confirmQuit: true,
                              Keys.quickViewStartsOn: StartPage.frontmostApp.rawValue])
        // A saved copy of 1.0.0's default follows the default to its new keys, once.
        if !d.bool(forKey: "movedOldDefaultHotKey") {
            d.set(true, forKey: "movedOldDefaultHotKey")
            if Self.decode(d.string(forKey: Keys.quickViewHotKey)) == Self.oldDefaultHotKey { d.removeObject(forKey: Keys.quickViewHotKey) }
        }
        quickViewHotKey = Self.storedHotKey()
        holdCommand = d.bool(forKey: Keys.holdCommand)
        quickViewStartsOn = StartPage(rawValue: d.string(forKey: Keys.quickViewStartsOn) ?? "") ?? .frontmostApp
        showDisabled = d.bool(forKey: Keys.showDisabled)
        scanSandboxed = d.bool(forKey: Keys.scanSandboxed)
        hiddenEntries = Set(d.stringArray(forKey: Keys.hiddenEntries) ?? [])
        hiddenApps = Set(d.stringArray(forKey: Keys.hiddenApps) ?? [])
        confirmQuit = d.bool(forKey: Keys.confirmQuit)
    }

    /// Re-reads everything, after settings sync wrote new values.
    func reload() {
        loading = true
        defer { loading = false }
        let hotKey = Self.storedHotKey()
        if quickViewHotKey != hotKey { quickViewHotKey = hotKey }
        if holdCommand != defaults.bool(forKey: Keys.holdCommand) { holdCommand = defaults.bool(forKey: Keys.holdCommand) }
        quickViewStartsOn = StartPage(rawValue: defaults.string(forKey: Keys.quickViewStartsOn) ?? "") ?? .frontmostApp
        if showDisabled != defaults.bool(forKey: Keys.showDisabled) { showDisabled = defaults.bool(forKey: Keys.showDisabled) }
        if scanSandboxed != defaults.bool(forKey: Keys.scanSandboxed) { scanSandboxed = defaults.bool(forKey: Keys.scanSandboxed) }
        hiddenEntries = Set(defaults.stringArray(forKey: Keys.hiddenEntries) ?? [])
        hiddenApps = Set(defaults.stringArray(forKey: Keys.hiddenApps) ?? [])
        confirmQuit = defaults.bool(forKey: Keys.confirmQuit)
    }

    private static func storedHotKey() -> KeyCombo? {
        let d = store
        return d.object(forKey: Keys.quickViewHotKey) == nil ? defaultHotKey : decode(d.string(forKey: Keys.quickViewHotKey))
    }

    /// Every synced value, defaults included, for the sync file.
    var snapshot: [String: Any] {
        [Keys.quickViewHotKey: encode(quickViewHotKey), Keys.holdCommand: holdCommand, Keys.quickViewStartsOn: quickViewStartsOn.rawValue,
         Keys.showDisabled: showDisabled, Keys.scanSandboxed: scanSandboxed, Keys.hiddenEntries: hiddenEntries.sorted(),
         Keys.hiddenApps: hiddenApps.sorted(), Keys.confirmQuit: confirmQuit]
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
        if !loading { SettingsSync.shared.localDidChange() }
    }

    /// "" means no shortcut (an absent key means the default).
    private func encode(_ combo: KeyCombo?) -> String {
        guard let combo, let data = try? JSONEncoder().encode(combo) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decode(_ string: String?) -> KeyCombo? {
        guard let string, !string.isEmpty else { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: Data(string.utf8))
    }

    func hide(_ entry: ShortcutEntry) { hiddenEntries.insert(entry.id) }
    func unhide(_ id: String) { hiddenEntries.remove(id) }
    func hideApp(_ ownerID: String) { hiddenApps.insert(ownerID) }
    func unhideApp(_ ownerID: String) { hiddenApps.remove(ownerID) }

    /// Back to how ShortcutsLens started; where it appears, login, sync and updates stay.
    func resetToDefaults() {
        quickViewHotKey = Self.defaultHotKey
        holdCommand = false
        quickViewStartsOn = .frontmostApp
        showDisabled = true
        scanSandboxed = false
        hiddenEntries = []
        hiddenApps = []
        confirmQuit = true
    }
}
