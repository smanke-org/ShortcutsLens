import AppKit
import Observation
import ShortcutsLensKit

/// Everything ShortcutsLens knows about shortcuts, kept up to date: a full scan on launch,
/// when asked, when an app launches or quits, and when ShortcutsLens comes to the front;
/// apps' own reports as they arrive.
@Observable
@MainActor
final class ShortcutStore {
    static let shared = ShortcutStore()

    /// From the scan, before reports and hiding.
    private var scanned: [ShortcutEntry] = []
    /// Reports by bundle id, newest per app.
    private var reports: [String: [ShortcutEntry]] = [:]
    private(set) var apps: [String: SystemSources.AppRecord] = [:]
    private(set) var running: Set<String> = []
    private(set) var isScanning = false
    private(set) var lastScan: Date?

    /// Every shortcut, reports in place of the scan's guesses for the apps that sent one.
    private(set) var all: [ShortcutEntry] = []
    private(set) var conflicts: [KeyCombo: [ShortcutEntry]] = [:]

    /// The app that was in front before ShortcutsLens (or the Quick View) came up.
    private(set) var frontmost: NSRunningApplication?
    private(set) var frontmostMenus: [ShortcutEntry] = []
    private(set) var readingMenus = false
    private(set) var accessibilityTrusted = MenuReader.isTrusted

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var rescanPending = false
    @ObservationIgnored private var frontmostPinned = false
    /// An agent CLI test copy (Debug, APP_STORE): it reads this Mac's shortcut sources but
    /// never asks apps for reports or listens for them; reports come from the test folder.
    @ObservationIgnored private var testRun = false

    private init() {}

    func start() {
        #if DEBUG
        testRun = AgentSocket.isTestRun
        #endif
        KeyboardLayout.install()
        running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        noteFrontmost(NSWorkspace.shared.frontmostApplication)
        #if DEBUG
        // Screenshots show a stock app in front, not whatever is in front on this Mac.
        if let id = ProcessInfo.processInfo.environment["SHORTCUTSLENS_DEBUG_FRONTMOST"],
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            noteFrontmost(app)
            frontmostPinned = true
        }
        #endif
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { ShortcutStore.shared.appLaunched(id) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { ShortcutStore.shared.appQuit(id) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { ShortcutStore.shared.noteFrontmost(app) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let store = ShortcutStore.shared
                store.accessibilityTrusted = MenuReader.isTrusted
                // Coming back to ShortcutsLens after changing a shortcut somewhere else.
                if let last = store.lastScan, Date().timeIntervalSince(last) > 5 { store.refresh() }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
                                                                object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KeyboardLayout.install(); ShortcutStore.shared.rebuild() }
        })
        if !testRun {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: .init(ShortcutReports.report), object: nil,
                                                                                 queue: .main) { note in
                let sender = note.object as? String
                let info = note.userInfo ?? [:]
                guard let sender, let entries = ShortcutReports.entries(sender: sender, userInfo: info) else { return }
                MainActor.assumeIsolated { ShortcutStore.shared.received(entries, from: sender) }
            })
        }
        #if DEBUG
        if testRun { loadTestReports() }
        #endif
        refresh()
    }

    // MARK: - Scanning

    func refresh() {
        guard !isScanning else { rescanPending = true; return }
        isScanning = true
        askForReports()
        let sandboxed = Preferences.shared.scanSandboxed
        Task.detached(priority: .userInitiated) {
            let result = SystemSources.collect(scanSandboxed: sandboxed)
            await MainActor.run {
                let store = ShortcutStore.shared
                store.scanned = result.entries
                store.apps = result.apps
                store.lastScan = Date()
                store.isScanning = false
                store.rebuild()
                if store.rescanPending {
                    store.rescanPending = false
                    store.refresh()
                }
            }
        }
    }

    func askForReports() {
        guard !testRun else { return }
        DistributedNotificationCenter.default().postNotificationName(.init(ShortcutReports.request), object: Bundle.main.bundleIdentifier,
                                                                     userInfo: nil, deliverImmediately: true)
    }

    private func received(_ entries: [ShortcutEntry], from sender: String) {
        reports[sender] = entries
        if apps[sender] == nil, let record = SystemSources.app(for: sender, sandboxed: false) { apps[sender] = record }
        rebuild()
    }

    #if DEBUG
    /// A test copy's reports: `<APP_STORE>/reports.json`, `{"<bundle id>": <a report's userInfo>}`,
    /// read as if each app had sent it.
    private func loadTestReports() {
        guard let folder = ProcessInfo.processInfo.environment["APP_STORE"],
              let data = FileManager.default.contents(atPath: folder + "/reports.json"),
              let all = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] else { return }
        for (sender, info) in all {
            if let entries = ShortcutReports.entries(sender: sender, userInfo: info) { received(entries, from: sender) }
        }
    }
    #endif

    private func appLaunched(_ id: String?) {
        guard let id else { return }
        running.insert(id)
        // A newly opened app may have just written its first settings.
        if apps[id] != nil || reports[id] != nil { scheduleRescan() }
    }

    private func appQuit(_ id: String?) {
        guard let id else { return }
        running.remove(id)
        // A report only describes a running app; its saved settings take over again.
        if reports.removeValue(forKey: id) != nil { rebuild() }
    }

    @ObservationIgnored private var rescanTask: Task<Void, Never>?
    private func scheduleRescan() {
        rescanTask?.cancel()
        rescanTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    /// Combines the scan and the reports, then finds conflicts.
    func rebuild() {
        var list = scanned.filter { entry in
            !((entry.source == .appSettings || entry.source == .knownDefault) && reports[entry.ownerID] != nil)
        }
        for (_, entries) in reports { list += entries }
        #if DEBUG
        // Screenshots for the public README show only these owners (id prefixes), not every
        // app on this Mac.
        if let only = ProcessInfo.processInfo.environment["SHORTCUTSLENS_DEBUG_ONLY_OWNERS"], !only.isEmpty {
            let prefixes = only.split(separator: ",").map(String.init)
            list = list.filter { entry in prefixes.contains { entry.ownerID.hasPrefix($0) } }
        }
        #endif
        // Our own Quick View shortcut, which no scan would see.
        if let combo = Preferences.shared.quickViewHotKey {
            list.append(ShortcutEntry(id: "own|quickview", ownerID: Bundle.main.bundleIdentifier ?? "com.smanke.ShortcutsLens",
                                      ownerName: AppInfo.name, title: "Show Quick View", combo: combo, source: .appReport,
                                      detail: "Change it in ShortcutsLens Settings › Quick View."))
        }
        all = list.sorted(by: Self.order)
        conflicts = Conflicts.find(in: all.filter { !isHidden($0) })
    }

    static func order(_ a: ShortcutEntry, _ b: ShortcutEntry) -> Bool {
        if a.ownerName != b.ownerName {
            // macOS first, then Services, then apps by name.
            let rank = { (e: ShortcutEntry) in e.ownerID == ShortcutEntry.macOSOwner ? 0 : e.ownerID == ShortcutEntry.servicesOwner ? 1 : 2 }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return a.ownerName.localizedStandardCompare(b.ownerName) == .orderedAscending
        }
        if (a.category ?? "") != (b.category ?? "") { return (a.category ?? "") < (b.category ?? "") }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }

    // MARK: - Questions the views ask

    func isHidden(_ entry: ShortcutEntry) -> Bool {
        let prefs = Preferences.shared
        return prefs.hiddenEntries.contains(entry.id) || prefs.hiddenApps.contains(entry.ownerID)
    }

    /// What lists show: hidden ones out, disabled ones out unless asked for.
    var visible: [ShortcutEntry] {
        let showDisabled = Preferences.shared.showDisabled
        return all.filter { !isHidden($0) && (showDisabled || $0.enabled) }
    }

    var globalVisible: [ShortcutEntry] { visible.filter(\.isGlobal) }

    func partners(of entry: ShortcutEntry) -> [ShortcutEntry] {
        Conflicts.partners(of: entry, in: conflicts)
    }

    func isRunning(_ ownerID: String) -> Bool {
        ownerID == ShortcutEntry.macOSOwner || ownerID == ShortcutEntry.servicesOwner || ownerID == ShortcutEntry.allAppsOwner
            || running.contains(ownerID) || KnownDefaults.helperIDs(for: ownerID).contains(where: running.contains)
    }

    /// Shortcuts on one combo, from every source including the frontmost app's menus.
    func uses(of combo: KeyCombo) -> [ShortcutEntry] {
        (all + frontmostMenus).filter { $0.combo == combo && !isHidden($0) }
    }

    func icon(for ownerID: String) -> NSImage {
        switch ownerID {
        case ShortcutEntry.macOSOwner:
            return NSImage(systemSymbolName: "apple.logo", accessibilityDescription: "macOS") ?? NSImage()
        case ShortcutEntry.servicesOwner:
            return NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: "Services") ?? NSImage()
        case ShortcutEntry.allAppsOwner:
            return NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: "All apps") ?? NSImage()
        case Bundle.main.bundleIdentifier:
            // Our own Quick View shortcut: a copy that Launch Services hasn't indexed has no URL.
            return NSApp.applicationIconImage
        default:
            if let url = apps[ownerID]?.url ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: ownerID) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        }
    }

    /// Apps with shortcuts, for the sidebar: (id, name), by name.
    var owners: [(id: String, name: String, count: Int)] {
        var counts: [String: (String, Int)] = [:]
        for entry in visible where ![ShortcutEntry.macOSOwner, ShortcutEntry.servicesOwner, ShortcutEntry.allAppsOwner].contains(entry.ownerID) {
            counts[entry.ownerID, default: (entry.ownerName, 0)].1 += 1
        }
        return counts.map { ($0.key, $0.value.0, $0.value.1) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - The app in front

    private func noteFrontmost(_ app: NSRunningApplication?) {
        guard !frontmostPinned, let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier, app.activationPolicy == .regular else { return }
        if frontmost?.processIdentifier != app.processIdentifier {
            frontmost = app
            frontmostMenus = []
        }
    }

    /// Reads the frontmost app's menus (Accessibility), for the sidebar's app page and the
    /// Quick View.
    func readFrontmostMenus() {
        accessibilityTrusted = MenuReader.isTrusted
        guard accessibilityTrusted, let app = frontmost, let id = app.bundleIdentifier else { return }
        let pid = app.processIdentifier
        let name = app.localizedName ?? id
        readingMenus = true
        Task.detached(priority: .userInitiated) {
            let entries = MenuReader.shortcuts(pid: pid, bundleID: id, appName: name)
            await MainActor.run {
                let store = ShortcutStore.shared
                store.readingMenus = false
                guard store.frontmost?.processIdentifier == pid else { return }
                store.frontmostMenus = entries
            }
        }
    }
}
