import AppKit
import ShortcutsLensKit

// ShortcutsLens's commands for agents. Each `run` asks ShortcutStore the same questions the
// window and the Quick View ask, so answers match what a person sees. ShortcutsLens can only
// read where shortcuts are written down (Keyboard settings, SkyLight's live values, apps'
// settings files, apps' own reports); nothing here presses keys to find out.

@MainActor
enum AgentCommands {
    nonisolated static let all: [AgentCommand] = [
        AgentCommand(
            name: "status",
            summary: "Whether ShortcutsLens is running, when it last scanned, and how many shortcuts, conflicts and apps it sees.",
            example: "shortcutslens status --json",
            readOnly: true,
            run: { _ in status() }),

        AgentCommand(
            name: "shortcuts list",
            summary: "Shortcuts ShortcutsLens found, macOS first, then apps by name. Hidden ones are left out.",
            params: [
                .init(name: "search", help: "words or keys to match: title, app, category or keys (\"screenshot\", \"⇧⌘4\")"),
                .init(name: "app", help: "only this app: a bundle id or app name, or macOS, Services, \"All apps\""),
                .init(name: "keys", help: "only shortcuts on these keys: \"⌃⌥⌘K\", \"cmd+shift+4\", or \"@$k\""),
                .init(name: "source", help: "only from one source: " + ShortcutSource.allCases.map(\.rawValue).joined(separator: ", ")),
                .init(name: "global", kind: .boolean, help: "only shortcuts that work in every app"),
                .init(name: "conflicts", kind: .boolean, help: "only shortcuts that collide with another one"),
                .init(name: "enabled", kind: .boolean, help: "only shortcuts that are turned on"),
                .init(name: "limit", kind: .integer, help: "how many to return (default 50)"),
                .init(name: "offset", kind: .integer, help: "skip this many (from nextOffset)"),
            ],
            example: "shortcutslens shortcuts list --search screenshot --json",
            readOnly: true,
            run: { args in try await listShortcuts(args) }),

        AgentCommand(
            name: "shortcuts show",
            summary: "One shortcut in full: where it came from, how to change it, and what else uses its keys.",
            params: [.init(name: "id", required: true, positional: true, help: "the shortcut's id from `shortcuts list` (any unique start)")],
            example: "shortcutslens shortcuts show 3f2a9c1e --json",
            readOnly: true,
            run: { args in try await showShortcut(args) }),

        AgentCommand(
            name: "conflicts list",
            summary: "Key combinations that two or more system-wide shortcuts claim, with every shortcut on each.",
            params: [
                .init(name: "app", help: "only conflicts that involve this app (bundle id or name)"),
                .init(name: "limit", kind: .integer, help: "how many conflicts to return (default 50)"),
                .init(name: "offset", kind: .integer, help: "skip this many (from nextOffset)"),
            ],
            example: "shortcutslens conflicts list --json",
            readOnly: true,
            run: { args in try await listConflicts(args) }),

        AgentCommand(
            name: "keys check",
            summary: "Whether a key combination is free: everything ShortcutsLens can see that uses it, if anything.",
            params: [.init(name: "keys", required: true, positional: true,
                           help: "the combination: \"⌃⌥⌘K\", \"ctrl+opt+cmd+k\", \"cmd shift space\", or \"@$k\"")],
            example: "shortcutslens keys check \"ctrl+opt+cmd+k\" --json",
            readOnly: true,
            run: { args in try await checkKeys(args) }),

        AgentCommand(
            name: "keys suggest",
            summary: "Free shortcuts: letters and digits on modifier sets that rarely clash with app menus, or every free key for one modifier set.",
            params: [
                .init(name: "modifiers", help: "only this modifier set: \"⌃⌥⌘\", \"ctrl+opt+cmd\", \"cmd+shift\""),
                .init(name: "limit", kind: .integer, help: "how many per modifier set (default 6)"),
            ],
            example: "shortcutslens keys suggest --modifiers ctrl+opt+cmd --json",
            readOnly: true,
            run: { args in try await suggestKeys(args) }),

        AgentCommand(
            name: "apps list",
            summary: "Apps with shortcuts, by name, with how many each has and whether it reported them itself.",
            params: [
                .init(name: "search", help: "part of the app's name or bundle id"),
                .init(name: "running", kind: .boolean, help: "only apps that are running"),
                .init(name: "limit", kind: .integer, help: "how many to return (default 50)"),
                .init(name: "offset", kind: .integer, help: "skip this many (from nextOffset)"),
            ],
            example: "shortcutslens apps list --running --json",
            readOnly: true,
            run: { args in try await listApps(args) }),

        AgentCommand(
            name: "shortcuts hide",
            summary: "Hides a shortcut from the lists and from conflicts, as Hide This Shortcut does. Undo with `shortcuts unhide`.",
            params: [.init(name: "id", required: true, positional: true, help: "the shortcut's id from `shortcuts list`")],
            example: "shortcutslens shortcuts hide 3f2a9c1e --json",
            run: { args in try await setHidden(args, hidden: true) }),

        AgentCommand(
            name: "shortcuts unhide",
            summary: "Shows a hidden shortcut again. `shortcuts list` leaves hidden ones out; `status` counts them.",
            params: [.init(name: "id", required: true, positional: true, help: "the shortcut's id")],
            example: "shortcutslens shortcuts unhide 3f2a9c1e --json",
            run: { args in try await setHidden(args, hidden: false) }),

        AgentCommand(
            name: "shortcuts rescan",
            summary: "Reads every source again (Keyboard settings, apps' settings, apps' reports) and waits for the result.",
            example: "shortcutslens shortcuts rescan --json",
            run: { _ in try await rescan() }),

        AgentCommand(
            name: "quickview open",
            summary: "Shows the Quick View panel (the app in front and system-wide shortcuts) on screen, as its hotkey does.",
            example: "shortcutslens quickview open",
            run: { _ in
                QuickView.shared.show()
                return ["shown": true]
            }),

        AgentCommand(
            name: "open",
            summary: "Shows a page of the ShortcutsLens window: " + pages.joined(separator: ", ") + ".",
            params: [.init(name: "page", positional: true, help: "the page (default all): " + pages.joined(separator: ", "))],
            example: "shortcutslens open conflicts",
            run: { args in try open(args) }),
    ]

    nonisolated static let pages = ["all", "conflicts", "keyboard", "free", "frontmost", "macos", "settings", "help"]

    // MARK: - Commands

    private static var store: ShortcutStore { .shared }

    private static func status() -> JSONObject {
        let all = store.all
        let reported = Set(all.filter { $0.source == .appReport }.map(\.ownerID))
        var result: JSONObject = [
            "running": true,
            "version": AppInfo.version,
            "scanning": store.isScanning,
            "shortcuts": all.count,
            "visible": store.visible.count,
            "hidden": all.filter(store.isHidden).count,
            "turnedOff": all.filter { !$0.enabled }.count,
            "conflicts": store.conflicts.count,
            "apps": store.owners.count,
            "appsReporting": reported.count,
            "liveValues": LiveHotKeys.isAvailable,
            "accessibility": store.accessibilityTrusted,
            "quickViewKeys": Preferences.shared.quickViewHotKey?.display ?? NSNull(),
        ]
        if let last = store.lastScan { result["lastScan"] = JSON.date(last) }
        if let front = store.frontmost { result["frontmostApp"] = front.localizedName ?? front.bundleIdentifier ?? NSNull() }
        if AgentSocket.isTestRun { result["testCopy"] = true }
        return result
    }

    private static func listShortcuts(_ args: Args) async throws -> JSONObject {
        try await scanned()
        var list = store.visible
        if let app = args.string("app") {
            let ids = try ownerIDs(matching: app)
            list = list.filter { ids.contains($0.ownerID) }
        }
        if let raw = args.string("keys") {
            let combo = try combo(raw)
            list = list.filter { $0.combo == combo }
        }
        if let raw = args.string("source") {
            guard let source = ShortcutSource(rawValue: raw) ?? ShortcutSource.allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() }) else {
                throw AgentError.usage("no source \"\(raw)\". Use one of: " + ShortcutSource.allCases.map(\.rawValue).joined(separator: ", "))
            }
            list = list.filter { $0.source == source }
        }
        if try args.bool("global") == true { list = list.filter(\.isGlobal) }
        if try args.bool("enabled") == true { list = list.filter(\.enabled) }
        if try args.bool("conflicts") == true { list = list.filter { !store.partners(of: $0).isEmpty } }
        if let search = args.string("search") { list = list.filter { $0.matches(search) } }
        return try page(list, args, key: "shortcuts", summary)
    }

    private static func showShortcut(_ args: Args) async throws -> JSONObject {
        try await scanned()
        let entry = try find(try args.required("id"))
        var result = summary(entry)
        result["spoken"] = entry.combo.spoken
        result["sourceTitle"] = entry.source.title
        result["hidden"] = store.isHidden(entry)
        if let detail = entry.detail { result["detail"] = detail }
        if let menuPath = entry.menuPath { result["menuPath"] = menuPath }
        if let gesture = entry.gestureTitle { result["gestureTitle"] = gesture }
        result["conflictsWith"] = store.partners(of: entry).map(brief)
        // Everything else on the same keys, app menus included (not all of those collide).
        result["sameKeys"] = store.uses(of: entry.combo).filter { $0.id != entry.id }.map(brief)
        return result
    }

    private static func listConflicts(_ args: Args) async throws -> JSONObject {
        try await scanned()
        var conflicts = store.conflicts.sorted { $0.key < $1.key }
        if let app = args.string("app") {
            let ids = try ownerIDs(matching: app)
            conflicts = conflicts.filter { $0.value.contains { ids.contains($0.ownerID) } }
        }
        return try page(conflicts, args, key: "conflicts") { combo, entries in
            ["keys": combo.display, "spoken": combo.spoken, "count": entries.count,
             "shortcuts": entries.sorted(by: ShortcutStore.order).map(brief)]
        }
    }

    private static func checkKeys(_ args: Args) async throws -> JSONObject {
        try await scanned()
        let combo = try combo(try args.required("keys"))
        // As Find a Free Shortcut answers: every enabled use, the app in front's menus included.
        let uses = store.uses(of: combo).filter(\.enabled)
        return ["keys": combo.display, "spoken": combo.spoken, "free": uses.isEmpty, "uses": uses.map(brief),
                "note": uses.isEmpty ? "Nothing ShortcutsLens can see uses \(combo.display). Apps that keep their shortcuts to themselves may still."
                    : "\(combo.display) is taken."]
    }

    private static func suggestKeys(_ args: Args) async throws -> JSONObject {
        try await scanned()
        let perSet = try args.int("limit", default: 6)
        guard perSet > 0 else { throw AgentError.usage("--limit must be 1 or more") }
        let groups: [JSONObject]
        if let raw = args.string("modifiers") {
            let combo = try combo(raw)
            guard combo.keyCode == nil else {
                throw AgentError.usage("--modifiers takes modifiers only, like \"ctrl+opt+cmd\" or \"⌃⌥⌘\"")
            }
            // Any key on the Keyboard Map that nothing system-wide uses with these modifiers.
            let free = KeyboardMap.freeKeys(modifiers: combo.modifiers, used: store.all).prefix(perSet)
            groups = [["modifiers": combo.modifiers.symbols,
                       "keys": free.map { KeyCombo(keyCode: $0, modifiers: combo.modifiers).display }]]
        } else {
            // The Keyboard Map's suggestions, grouped by modifier set.
            let found = KeyboardMap.suggestions(used: store.all, perSet: perSet)
            groups = KeyboardMap.suggestedModifierSets.map { mods in
                ["modifiers": mods.symbols, "keys": found.filter { $0.modifiers == mods }.map(\.display)]
            }
        }
        return ["suggestions": groups, "count": groups.count,
                "note": "Free of every system-wide shortcut ShortcutsLens can see. Check one with `shortcutslens keys check`."]
    }

    private static func listApps(_ args: Args) async throws -> JSONObject {
        try await scanned()
        let visible = store.visible
        var owners = store.owners
        if let search = args.string("search") {
            owners = owners.filter {
                $0.name.range(of: search, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    || $0.id.range(of: search, options: .caseInsensitive) != nil
            }
        }
        if try args.bool("running") == true { owners = owners.filter { store.isRunning($0.id) } }
        return try page(owners, args, key: "apps") { owner in
            let mine = visible.filter { $0.ownerID == owner.id }
            return ["name": owner.name, "bundleId": owner.id, "shortcuts": owner.count, "running": store.isRunning(owner.id),
                    "reported": mine.contains { $0.source == .appReport },
                    "conflicts": mine.filter { !store.partners(of: $0).isEmpty }.count]
        }
    }

    private static func setHidden(_ args: Args, hidden: Bool) async throws -> JSONObject {
        try await scanned()
        let entry = try find(try args.required("id"))
        let was = Preferences.shared.hiddenEntries.contains(entry.id)
        if was != hidden {
            // As the window's Hide This Shortcut and Settings › Sources › Show do.
            if hidden { Preferences.shared.hide(entry) } else { Preferences.shared.unhide(entry.id) }
            store.rebuild()
        }
        var result = summary(entry)
        result["hidden"] = store.isHidden(entry)
        result["changed"] = was != hidden
        if !hidden, Preferences.shared.hiddenApps.contains(entry.ownerID) {
            result["note"] = "Everything from \(entry.ownerName) is hidden. Show it again in ShortcutsLens Settings › Sources."
        }
        return result
    }

    private static func rescan() async throws -> JSONObject {
        let before = store.lastScan
        store.refresh()
        try await waitFor(timeout: 60) { store.lastScan != before && !store.isScanning }
        // A moment for apps' reports to arrive, as the window gets.
        try? await Task.sleep(for: .seconds(1))
        return status()
    }

    private static func open(_ args: Args) throws -> JSONObject {
        let name = (args.string("page") ?? "all").lowercased()
        switch name {
        case "all": MainWindow.shared.show(.all)
        case "conflicts": MainWindow.shared.show(.conflicts)
        case "keyboard": MainWindow.shared.show(.keyboard)
        case "free": MainWindow.shared.show(.free)
        case "frontmost": MainWindow.shared.show(.frontmost)
        case "macos": MainWindow.shared.show(.macOS)
        case "settings": SettingsWindow.shared.show()
        case "help": HelpWindow.shared.show()
        default: throw AgentError.notFound("no page \"\(name)\". Pages: " + pages.joined(separator: ", "))
        }
        return ["page": name, "shown": true]
    }

    // MARK: - Helpers

    /// Waits for the first scan, which a freshly opened app is still running.
    private static func scanned() async throws {
        try await waitFor(timeout: 60) { store.lastScan != nil }
    }

    private static func waitFor(timeout: Double, _ done: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() {
            guard Date() < deadline else { throw AgentError.busy("ShortcutsLens is still scanning. Try again in a moment") }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// Stable short ids: the first 8 hex digits of a hash of the entry's own id, which stays the
    /// same across scans (hiding one relies on that too).
    static func shortID(_ entry: ShortcutEntry) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in entry.id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        // FNV alone leaves the top bits alike for ids that differ near the end; mix them.
        hash ^= hash >> 33
        hash = hash &* 0xff51_afd7_ed55_8ccd
        hash ^= hash >> 33
        return String(String(format: "%016llx", hash).prefix(8))
    }

    private static func find(_ id: String) throws -> ShortcutEntry {
        let key = id.lowercased()
        let candidates = store.all + store.frontmostMenus
        if let exact = candidates.first(where: { $0.id == id }) { return exact }
        let matches = candidates.filter { shortID($0).hasPrefix(key) }
        guard !matches.isEmpty else { throw AgentError.notFound("no shortcut with id \(id). Run `shortcutslens shortcuts list`") }
        guard Set(matches.map(\.id)).count == 1 else {
            throw AgentError.usage("id \(id) matches \(matches.count) shortcuts. Give more of it")
        }
        return matches[0]
    }

    private static func combo(_ raw: String) throws -> KeyCombo {
        guard let combo = KeyEquivalentParser.parseReadable(raw) ?? KeyEquivalentParser.parseKeyEquivalent(raw) else {
            throw AgentError.usage("can't read \"\(raw)\" as keys. Write it like \"⌃⌥⌘K\", \"ctrl+opt+cmd+k\", \"cmd shift space\", or \"@$k\"")
        }
        return combo
    }

    /// Owner ids for --app: a bundle id, or an owner's name (macOS, Services and "All apps" too).
    private static func ownerIDs(matching app: String) throws -> Set<String> {
        let owners = Dictionary(store.all.map { ($0.ownerID, $0.ownerName) }, uniquingKeysWith: { a, _ in a })
        if owners[app] != nil { return [app] }
        let byName = Set(owners.filter { $0.value.caseInsensitiveCompare(app) == .orderedSame }.keys)
        if !byName.isEmpty { return byName }
        let partial = Set(owners.filter { $0.value.range(of: app, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.keys)
        guard !partial.isEmpty else { throw AgentError.notFound("no app with shortcuts called \(app). Run `shortcutslens apps list`") }
        return partial
    }

    private static func summary(_ entry: ShortcutEntry) -> JSONObject {
        var result: JSONObject = [
            "id": shortID(entry), "title": entry.title, "app": entry.ownerName, "appId": entry.ownerID,
            "keys": entry.combo.display, "source": entry.source.rawValue, "enabled": entry.enabled, "global": entry.isGlobal,
            "conflicts": store.partners(of: entry).count,
        ]
        if let category = entry.category { result["category"] = category }
        if let gesture = entry.gesture { result["gesture"] = gesture }
        return result
    }

    private static func brief(_ entry: ShortcutEntry) -> JSONObject {
        ["id": shortID(entry), "title": entry.title, "app": entry.ownerName, "keys": entry.combo.display, "source": entry.source.rawValue]
    }

    /// A page of a list: `--limit` (default 50) from `--offset`, with the total and the next offset.
    private static func page<T>(_ items: [T], _ args: Args, key: String, _ map: (T) -> JSONObject) throws -> JSONObject {
        let limit = try args.int("limit", default: 50)
        let offset = try args.int("offset", default: 0)
        guard limit > 0, offset >= 0 else { throw AgentError.usage("--limit must be 1 or more and --offset 0 or more") }
        let slice = items.dropFirst(offset).prefix(limit)
        var result: JSONObject = [key: slice.map(map), "total": items.count]
        if offset + slice.count < items.count { result["nextOffset"] = offset + slice.count }
        return result
    }
}
