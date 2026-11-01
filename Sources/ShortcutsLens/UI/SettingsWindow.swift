import AppKit
import ShortcutsLensKit
import SwiftUI

/// The panes, down the sidebar.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, quickView, sources, sync, updates

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .quickView: "Quick View"
        case .sources: "Sources"
        case .sync: "Sync"
        case .updates: "Updates"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .quickView: "rectangle.on.rectangle"
        case .sources: "tray.full"
        case .sync: "icloud"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }
}

/// Settings in an AppKit window with a sidebar, so the Dock menu and the menu bar item can
/// open it (SwiftUI's Settings scene can't be opened from AppKit). It scrolls, drags bigger,
/// and keeps the size you leave it at.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    private var window: NSWindow?
    fileprivate let selection = PaneSelection()

    func show(_ pane: SettingsPane? = nil) {
        LaunchAtLogin.shared.refresh()
        if let pane { selection.pane = pane }
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsRoot(selection: selection))
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
            window.setContentSize(NSSize(width: 760, height: min(560, visible.height - 80)))
            window.contentMinSize = Self.minimumContentSize
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("ShortcutsLensSettings")
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.title = "ShortcutsLens Settings"
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // After an update whose notes weren't seen yet.
        if let window { WhatsNew.shared.present(on: window) }
    }

    /// The smallest the window can be dragged to. Also set as contentMinSize, but a window
    /// whose content is a hosting controller drops that once it's shown, so a drag is held
    /// to it in windowWillResize.
    static let minimumContentSize = NSSize(width: 640, height: 280)

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minimum = sender.frameRect(forContentRect: NSRect(origin: .zero, size: Self.minimumContentSize)).size
        return NSSize(width: max(frameSize.width, minimum.width), height: max(frameSize.height, minimum.height))
    }

    func windowWillClose(_ notification: Notification) {
        AppPresence.applyDock(keepInFront: nil)
    }

    /// This version's release notes, when asked for from Settings.
    func showWhatsNew() {
        if let window { WhatsNew.shared.present(on: window, asked: true) }
    }

    #if DEBUG
    var debugWindow: NSWindow? { window }
    #endif
}

@Observable
@MainActor
final class PaneSelection {
    var pane: SettingsPane = .general
}

struct SettingsRoot: View {
    @State var selection: PaneSelection

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding<SettingsPane?>(get: { selection.pane },
                                                                          set: { if let p = $0 { selection.pane = p } })) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            VStack(spacing: 0) {
                switch selection.pane {
                case .general: GeneralSettings()
                case .quickView: QuickViewSettings()
                case .sources: SourcesSettings()
                case .sync: SyncSettings()
                case .updates: UpdateSettings()
                }
                // The version in the middle, the round Help button in the corner, as macOS does.
                ZStack {
                    Text("\(AppInfo.name) \(AppInfo.displayVersion)")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        HelpButton(topic: Help.topic(for: selection.pane)).fixedSize()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .navigationTitle(selection.pane.title)
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @State private var prefs = Preferences.shared
    @State private var presence = PresenceSettings.shared
    @State private var hub = MenuHub.shared
    @State private var login = LaunchAtLogin.shared
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                AppearancePicker { SettingsSync.shared.localDidChange() }
            } footer: {
                Text(AppAppearance.footer(appName: "ShortcutsLens")).font(.caption).foregroundStyle(.secondary)
            }
            Section("Where ShortcutsLens appears") {
                Toggle("Show in Dock", isOn: $presence.showInDock)
                Toggle("Show in menu bar", isOn: $presence.showInMenuBar)
                Toggle("Put in ToolHUD’s menu while ToolHUD is running", isOn: $hub.foldIntoToolHUD)
                    .help("ToolHUD shows ShortcutsLens’s menu as a submenu of its own, and ShortcutsLens’s icon leaves the menu bar until ToolHUD quits.")
                if !presence.showInDock && !presence.showInMenuBar {
                    Text(AppPresence.hiddenEverywhereNote(appName: "ShortcutsLens", settingsName: "the ShortcutsLens window"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Open ShortcutsLens at login", isOn: Binding(get: { login.isEnabled }, set: { login.set($0) }))
                if login.needsApproval {
                    Button("Allow in Login Items…") { login.openLoginItemsSettings() }
                }
                if let error = login.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                Toggle("Ask before quitting", isOn: $prefs.confirmQuit)
                    .help("Quitting ShortcutsLens asks first, so a stray ⌘Q doesn't take the Quick View away.")
            } footer: {
                Text("The Quick View shortcut works only while ShortcutsLens is running, so opening it at login keeps it ready.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Accessibility") {
                    if ShortcutStore.shared.accessibilityTrusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Allow…") { MenuReader.requestAccess() }
                    }
                }
            } header: {
                Text("Permission")
            } footer: {
                Text("Optional. With it, ShortcutsLens can read the menus of the app you're using and show the Quick View while you hold ⌘. Everything else works without it. ShortcutsLens never asks for Full Disk Access.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("About") {
                    HStack {
                        Button("About ShortcutsLens") { AppInfo.showAbout() }
                        Button("Our other apps…") {
                            if let url = URL(string: "https://stevemanke.com/") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                LabeledContent("Options and hidden shortcuts") {
                    Button("Reset to Defaults…") { confirmReset = true }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { login.refresh() }
        .confirmationDialog("Reset ShortcutsLens settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { prefs.resetToDefaults(); ShortcutStore.shared.rebuild() }
        } message: {
            Text("The Quick View shortcut goes back to ⌃⌥⌘K, hidden shortcuts and apps come back, and the options go back to how ShortcutsLens started. Where it appears, login, sync and updates stay as they are.")
        }
    }
}

// MARK: - Quick View

struct QuickViewSettings: View {
    @State private var prefs = Preferences.shared
    @State private var hotkeys = HotKeyCenter.shared
    @State private var store = ShortcutStore.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Quick View shortcut") { ShortcutRecorder(combo: $prefs.quickViewHotKey) }
                if hotkeys.registrationFailed, let key = prefs.quickViewHotKey {
                    Text("Another app is already using \(key.display). Pick another shortcut.").font(.caption).foregroundStyle(.red)
                } else if let key = prefs.quickViewHotKey {
                    ComboUsage(combo: key, ignoring: "own|quickview").font(.caption)
                }
                Toggle("Also show it while I hold ⌘", isOn: $prefs.holdCommand)
                if prefs.holdCommand && !store.accessibilityTrusted {
                    LabeledContent {
                        Button("Allow…") { MenuReader.requestAccess() }
                    } label: {
                        Text("Holding ⌘ in other apps needs Accessibility permission.").foregroundStyle(.orange)
                    }
                }
                Picker("Open on", selection: $prefs.quickViewStartsOn) {
                    ForEach(Preferences.StartPage.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("The shortcut opens the Quick View for searching; press it again or Esc to close it. Holding ⌘ by itself for a second shows it until you let go. Click the shortcut above, then press new keys; Delete clears it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Sources

struct SourcesSettings: View {
    @State private var prefs = Preferences.shared
    @State private var store = ShortcutStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("Show turned-off shortcuts", isOn: $prefs.showDisabled)
                Toggle("Also look in sandboxed apps", isOn: $prefs.scanSandboxed)
            } footer: {
                Text("ShortcutsLens reads macOS's shortcut settings, the Services and App Shortcuts lists, and the settings files apps keep in your Library. App Store apps keep theirs in a sandbox; looking there makes macOS ask once whether ShortcutsLens may see other apps' data. Apps that keep their shortcuts somewhere else can't be seen, so no list like this is ever complete.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Last scan") {
                    HStack {
                        if store.isScanning { ProgressView().controlSize(.small) }
                        Text(store.lastScan.map { $0.formatted(date: .omitted, time: .standard) } ?? "Not yet")
                        Button("Rescan") { store.refresh() }
                    }
                }
                LabeledContent("macOS live values") {
                    Text(LiveHotKeys.isAvailable ? "Read from the system" : "From settings files only")
                }
            }
            Section("Hidden apps") {
                if prefs.hiddenApps.isEmpty {
                    Text("None. Right-click an app in the sidebar to hide everything from it.").foregroundStyle(.secondary)
                }
                ForEach(prefs.hiddenApps.sorted(), id: \.self) { id in
                    LabeledContent(store.apps[id]?.name ?? id) {
                        Button("Show") { prefs.unhideApp(id); store.rebuild() }
                    }
                }
            }
            Section("Hidden shortcuts") {
                if prefs.hiddenEntries.isEmpty {
                    Text("None. Right-click a shortcut to hide it.").foregroundStyle(.secondary)
                }
                ForEach(prefs.hiddenEntries.sorted(), id: \.self) { id in
                    let entry = store.all.first { $0.id == id }
                    LabeledContent {
                        Button("Show") { prefs.unhide(id); store.rebuild() }
                    } label: {
                        if let entry {
                            HStack { Keycaps(combo: entry.combo, size: .small); Text("\(entry.ownerName): \(entry.title)") }
                        } else {
                            Text(id).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Sync

struct SyncSettings: View {
    @State private var sync = SettingsSync.shared

    var body: some View {
        Form {
            Section {
                Toggle("Sync settings with your other Macs", isOn: $sync.isEnabled)
                if sync.isEnabled {
                    LabeledContent {
                        Button("Sync Now") { sync.syncNow() }
                    } label: {
                        if let error = sync.lastError {
                            Text(error).foregroundStyle(.red)
                        } else if let date = sync.lastSynced {
                            Text("Synced \(date.formatted(date: .omitted, time: .shortened))\(sync.lastSource.map { $0 == SettingsSync.deviceName ? "" : " from \($0)" } ?? "")")
                        } else {
                            Text("Waiting for iCloud Drive…")
                        }
                    }
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text("The Quick View shortcut and options, hidden shortcuts and apps, appearance, where ShortcutsLens appears and the update choice follow you to every Mac signed in to the same iCloud account with sync turned on. Open at login stays on each Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Updates

struct UpdateSettings: View {
    @State private var updater = AutoUpdater.shared

    private var footer: String {
        switch updater.policy {
        case .automatic:
            "ShortcutsLens checks \(updater.interval.phrase). A new version installs itself when the Quick View isn't open, no app is keeping the screen awake and your Mac hasn't been used for 2 minutes. You'll get a notification when it's done."
        case .ask:
            "ShortcutsLens checks \(updater.interval.phrase) and sends a notification when a new version is out. Nothing installs until you choose to."
        case .off:
            "ShortcutsLens won't look for updates on its own. Use Check Now whenever you like."
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("When an update is available", selection: $updater.policy) {
                    ForEach(UpdatePolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if updater.policy != .off {
                    UpdateIntervalPicker(interval: $updater.interval)
                }
                if let staged = updater.staged {
                    LabeledContent("Version \(staged.version) is ready") {
                        Button("Install Now") { updater.installNow() }
                    }
                }
                LabeledContent("Version \(AppInfo.displayVersion)") {
                    HStack {
                        Button("What's New…") { SettingsWindow.shared.showWhatsNew() }
                        Button("Check Now") { UpdateController.checkForUpdates() }
                    }
                }
                if let error = updater.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                if updater.policy != .off && !updater.notificationsAllowed {
                    LabeledContent {
                        Button("Open Notification Settings") { AutoUpdater.openNotificationSettings() }
                    } label: {
                        Label("Notifications are off for ShortcutsLens, so update news only shows in the menu.",
                              systemImage: "bell.slash").foregroundStyle(.orange)
                    }
                }
            } footer: {
                Text(footer).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { updater.refreshNotificationStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            updater.refreshNotificationStatus()
        }
    }
}
