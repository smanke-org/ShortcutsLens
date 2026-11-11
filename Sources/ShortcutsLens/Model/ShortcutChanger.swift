import AppKit
import Observation
import ShortcutsLensKit

/// Gives a shortcut new keys where ShortcutsLens can do that safely:
/// - macOS's own (Keyboard settings): written to `com.apple.symbolichotkeys` and handed to the
///   WindowServer, so it works at once.
/// - App Shortcuts (`NSUserKeyEquivalents`): written to the app's settings; the app reads them
///   when it next opens.
/// - The user's own apps that say they take changes: asked over a distributed notification;
///   the app saves the keys in its own settings and reports again.
/// - ShortcutsLens's own Quick View shortcut.
/// Other apps' settings files are never written: their formats are private and a running app
/// would overwrite them anyway.
///
/// Every change is remembered per Mac (not synced), so it can be undone.
@Observable
@MainActor
final class ShortcutChanger {
    static let shared = ShortcutChanger()

    struct Record: Codable, Hashable {
        var entryID: String
        var title: String
        var ownerName: String
        var old: KeyCombo
        var new: KeyCombo
        var date: Date
    }

    enum Target {
        case macOS(id: Int)
        case menu(domain: String, key: String)
        case app(bundleID: String, id: String)
        case quickView
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The last change to each shortcut, by entry id.
    private(set) var records: [String: Record] = [:]
    private let defaultsKey = "shortcutChanges"

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let list = try? JSONDecoder().decode([Record].self, from: data) {
            records = Dictionary(list.map { ($0.entryID, $0) }, uniquingKeysWith: { a, b in a.date > b.date ? a : b })
        }
    }

    // MARK: - What can be changed

    func target(for entry: ShortcutEntry) -> Target? {
        switch entry.source {
        case .macOS:
            guard let id = Int(entry.id.dropFirst("macOS|".count)) else { return nil }
            return .macOS(id: id)
        case .menuOverride:
            // "menu|<owner>|<the key in NSUserKeyEquivalents>"
            let parts = entry.id.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            let owner = String(parts[1])
            // A sandboxed app's settings live in its container, which only it should write.
            if owner != ShortcutEntry.allAppsOwner, ShortcutStore.shared.apps[owner]?.sandboxed == true { return nil }
            return .menu(domain: owner, key: String(parts[2]))
        case .appReport:
            if entry.id == "own|quickview" { return .quickView }
            guard entry.changeable else { return nil }
            let parts = entry.id.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            return .app(bundleID: String(parts[1]), id: String(parts[2]))
        case .builtIn, .services, .appSettings, .appMenus, .knownDefault:
            return nil
        }
    }

    func canChange(_ entry: ShortcutEntry) -> Bool { target(for: entry) != nil }

    /// What happens when the keys change, for the Change sheet.
    func explanation(for entry: ShortcutEntry) -> String {
        switch target(for: entry) {
        case .macOS: "Saved in Keyboard settings, the same place System Settings › Keyboard › Keyboard Shortcuts saves it. Works right away."
        case .menu(let domain, _):
            domain == ShortcutEntry.allAppsOwner
                ? "Saved in App Shortcuts for all apps. Each app uses it the next time it opens."
                : "Saved in App Shortcuts for \(entry.ownerName). \(entry.ownerName) uses it the next time it opens."
        case .app: "\(entry.ownerName) saves it in its own settings, as if you'd changed it there. Works right away."
        case .quickView: "Saved in ShortcutsLens's settings. Works right away."
        case nil: "ShortcutsLens can't change this one."
        }
    }

    /// Why a shortcut can't be changed here, for the inspector.
    func reasonNotChangeable(_ entry: ShortcutEntry) -> String? {
        switch entry.source {
        case .builtIn: return nil
        case .appSettings, .knownDefault:
            return "ShortcutsLens doesn't write other apps' settings: each keeps them its own way and would overwrite a change while it runs. Change it in \(entry.ownerName)."
        case .appReport where !entry.changeable:
            return "This version of \(entry.ownerName) can't take a new shortcut from ShortcutsLens yet. Change it in \(entry.ownerName)."
        case .menuOverride where target(for: entry) == nil:
            return "\(entry.ownerName) keeps its settings in its own container. Change it in System Settings › Keyboard › Keyboard Shortcuts › App Shortcuts."
        default: return nil
        }
    }

    // MARK: - Changing

    /// Gives `entry` new keys and remembers the old ones.
    func change(_ entry: ShortcutEntry, to combo: KeyCombo) async throws {
        guard let target = target(for: entry) else { throw Failure(message: "ShortcutsLens can't change this shortcut.") }
        guard combo.keyCode != nil else { throw Failure(message: "Choose a key as well as modifiers.") }
        try await apply(combo, to: target, entry: entry)
        let previous = records[entry.id]
        // Undoing returns to the first keys, not to an in-between change.
        let record = Record(entryID: entry.id, title: entry.title, ownerName: entry.ownerName,
                            old: previous?.old ?? entry.combo, new: combo, date: Date())
        records[entry.id] = record.old == combo ? nil : record
        save()
        ShortcutStore.shared.refresh()
    }

    /// Puts back the keys the shortcut had before ShortcutsLens first changed it.
    func undo(_ entry: ShortcutEntry) async throws {
        guard let record = records[entry.id] else { return }
        try await change(entry, to: record.old)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Array(records.values)) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func apply(_ combo: KeyCombo, to target: Target, entry: ShortcutEntry) async throws {
        switch target {
        case .macOS(let id): try setMacOS(id: id, combo: combo, enabled: entry.enabled)
        case .menu(let domain, let key): try setMenu(domain: domain, key: key, combo: combo)
        case .app(let bundleID, let id): try await AppChangeRequest.send(bundleID: bundleID, id: id, combo: combo, appName: entry.ownerName)
        case .quickView: Preferences.shared.quickViewHotKey = combo
        }
    }

    // MARK: macOS

    private static let symbolicDomain = "com.apple.symbolichotkeys" as CFString
    private static let symbolicKey = "AppleSymbolicHotKeys" as CFString

    private func setMacOS(id: Int, combo: KeyCombo, enabled: Bool) throws {
        guard let parameters = KeyWriter.symbolicParameters(combo) else { throw Failure(message: "macOS can't use those keys.") }
        var all = CFPreferencesCopyAppValue(Self.symbolicKey, Self.symbolicDomain) as? [String: Any] ?? [:]
        all[String(id)] = ["enabled": enabled, "value": ["parameters": parameters, "type": "standard"]] as [String: Any]
        CFPreferencesSetAppValue(Self.symbolicKey, all as CFDictionary, Self.symbolicDomain)
        guard CFPreferencesAppSynchronize(Self.symbolicDomain) else { throw Failure(message: "macOS didn't save the change.") }
        // The WindowServer reads the file only at login; tell it now.
        LiveHotKeys.set(id: id, character: parameters[0], keyCode: parameters[1], modifiers: parameters[2])
    }

    // MARK: App Shortcuts

    private func setMenu(domain: String, key: String, combo: KeyCombo) throws {
        guard let equivalent = KeyWriter.keyEquivalent(combo) else { throw Failure(message: "Menus can't use that key.") }
        let app: CFString = domain == ShortcutEntry.allAppsOwner ? kCFPreferencesAnyApplication : domain as CFString
        var all = CFPreferencesCopyAppValue("NSUserKeyEquivalents" as CFString, app) as? [String: Any] ?? [:]
        all[key] = equivalent
        CFPreferencesSetAppValue("NSUserKeyEquivalents" as CFString, all as CFDictionary, app)
        guard CFPreferencesAppSynchronize(app) else { throw Failure(message: "The change couldn't be saved.") }
    }
}

/// Asks one of the user's apps to use new keys and waits for its answer.
@MainActor
enum AppChangeRequest {
    static func send(bundleID: String, id: String, combo: KeyCombo, appName: String) async throws {
        // The entry came from the app's report, and reports go when the app quits, so it's
        // running; a timeout covers an app that hangs.
        let requestID = UUID().uuidString
        let center = DistributedNotificationCenter.default()
        let answer: (ok: Bool, message: String?)? = await withCheckedContinuation { continuation in
            var observer: NSObjectProtocol?
            var finished = false
            let finish: @MainActor ((Bool, String?)?) -> Void = { result in
                guard !finished else { return }
                finished = true
                if let observer { center.removeObserver(observer) }
                continuation.resume(returning: result.map { (ok: $0.0, message: $0.1) })
            }
            observer = center.addObserver(forName: .init(ShortcutReports.changed), object: bundleID, queue: .main) { note in
                let info = note.userInfo ?? [:]
                guard info["requestID"] as? String == requestID else { return }
                let ok = info["ok"] as? Bool ?? false
                let message = info["message"] as? String
                MainActor.assumeIsolated { finish((ok, message)) }
            }
            center.postNotificationName(.init(ShortcutReports.change), object: bundleID,
                                        userInfo: ["id": id, "keyCode": combo.keyCode ?? -1,
                                                   "carbonModifiers": combo.modifiers.carbon, "requestID": requestID],
                                        deliverImmediately: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { MainActor.assumeIsolated { finish(nil) } }
        }
        guard let answer else { throw ShortcutChanger.Failure(message: "\(appName) didn't answer. Change it in \(appName)'s settings.") }
        guard answer.ok else { throw ShortcutChanger.Failure(message: answer.message ?? "\(appName) couldn't use those keys.") }
    }
}
