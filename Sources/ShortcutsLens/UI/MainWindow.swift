import AppKit
import Observation
import ShortcutsLensKit
import SwiftUI

/// What the sidebar can show.
enum Page: Hashable {
    case all, conflicts, keyboard, free, frontmost, macOS, services, menuOverrides, app(String)

    @MainActor var title: String {
        switch self {
        case .all: "All Shortcuts"
        case .conflicts: "Conflicts"
        case .keyboard: "Keyboard Map"
        case .free: "Find a Free Shortcut"
        case .frontmost: "App in Front"
        case .macOS: "macOS"
        case .services: "Services"
        case .menuOverrides: "App Shortcuts"
        case .app(let id): ShortcutStore.shared.owners.first { $0.id == id }?.name ?? id
        }
    }
}

@Observable
@MainActor
final class WindowState {
    var page: Page = .all
    var search = ""
    var selection: ShortcutEntry.ID?
}

/// The main window.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    static let shared = MainWindow()
    let state = WindowState()
    private var window: NSWindow?

    func show(_ page: Page? = nil) {
        if let page { state.page = page }
        if window == nil {
            let hosting = NSHostingController(rootView: MainView(state: state))
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 1040, height: 680))
            window.contentMinSize = NSSize(width: 820, height: 480)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("ShortcutsLensMain")
            window.delegate = self
            window.center()
            self.window = window
        }
        setTitle(state.page.title)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if state.page == .frontmost { ShortcutStore.shared.readFrontmostMenus() }
    }

    var isVisible: Bool { window?.isVisible == true }

    func setTitle(_ title: String) { window?.title = title }

    func windowWillClose(_ notification: Notification) {
        AppPresence.applyDock(keepInFront: nil)
    }

    #if DEBUG
    var debugWindow: NSWindow? { window }
    #endif
}

struct MainView: View {
    @State var state: WindowState
    @State private var store = ShortcutStore.shared
    @State private var prefs = Preferences.shared

    var body: some View {
        NavigationSplitView {
            Sidebar(state: state)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            detail
                .navigationTitle(state.page.title)
                .navigationSubtitle(subtitle)
                // The hosted split view doesn't hand its title to the window.
                .onChange(of: state.page, initial: true) { MainWindow.shared.setTitle(state.page.title) }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if store.isScanning { ProgressView().controlSize(.small) }
                Button { store.refresh(); if state.page == .frontmost { store.readFrontmostMenus() } } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .help("Look for shortcuts again (⌘R)")
                .keyboardShortcut("r")
                Toggle(isOn: $prefs.showDisabled) { Label("Show Turned-Off Shortcuts", systemImage: "eye") }
                    .help("Show shortcuts that are turned off")
                Button { QuickView.shared.show() } label: { Label("Quick View", systemImage: "rectangle.on.rectangle") }
                    .help("Open the Quick View" + (prefs.quickViewHotKey.map { " (\($0.display))" } ?? ""))
            }
        }
    }

    private var subtitle: String {
        switch state.page {
        case .keyboard, .free: ""
        case .frontmost: store.frontmost?.localizedName ?? ""
        default: "\(entries.count) shortcut\(entries.count == 1 ? "" : "s")"
        }
    }

    @ViewBuilder private var detail: some View {
        switch state.page {
        case .keyboard: KeyboardMapView()
        case .free: FreeShortcutsView()
        case .frontmost: FrontmostView(state: state)
        default: ShortcutList(state: state, entries: entries, showOwner: showOwner)
        }
    }

    private var showOwner: Bool {
        switch state.page {
        case .app, .macOS, .services: false
        default: true
        }
    }

    var entries: [ShortcutEntry] {
        let list: [ShortcutEntry]
        switch state.page {
        case .all: list = store.visible
        case .conflicts: list = store.visible.filter { !store.partners(of: $0).isEmpty }.sorted { $0.combo < $1.combo }
        case .macOS: list = store.visible.filter { $0.ownerID == ShortcutEntry.macOSOwner }
        case .services: list = store.visible.filter { $0.source == .services }
        case .menuOverrides: list = store.visible.filter { $0.source == .menuOverride }
        case .app(let id): list = store.visible.filter { $0.ownerID == id }
        case .frontmost: list = store.frontmostMenus
        case .keyboard, .free: list = []
        }
        return list.filter { $0.matches(state.search) }
    }
}

struct Sidebar: View {
    @State var state: WindowState
    @State private var store = ShortcutStore.shared

    var body: some View {
        List(selection: Binding<Page?>(get: { state.page }, set: { if let p = $0 { state.page = p; state.selection = nil } })) {
            Section {
                row(.all, "keyboard", count: store.visible.count)
                // Counted by keys, as the menu counts them.
                row(.conflicts, "exclamationmark.triangle", count: store.conflicts.count,
                    tint: store.conflicts.isEmpty ? nil : .orange)
                row(.keyboard, "keyboard.badge.ellipsis")
                row(.free, "sparkle.magnifyingglass")
                frontmostRow
            }
            Section("System") {
                row(.macOS, "apple.logo", count: store.visible.filter { $0.ownerID == ShortcutEntry.macOSOwner }.count)
                let services = store.visible.filter { $0.source == .services }.count
                if services > 0 { row(.services, "gearshape.2", count: services) }
                let overrides = store.visible.filter { $0.source == .menuOverride }.count
                if overrides > 0 { row(.menuOverrides, "menubar.rectangle", count: overrides) }
            }
            Section("Apps") {
                ForEach(store.owners, id: \.id) { owner in
                    Label {
                        HStack {
                            Text(owner.name).lineLimit(1)
                            if !store.isRunning(owner.id) {
                                Image(systemName: "moon.zzz").font(.caption2).foregroundStyle(.tertiary)
                                    .help("Not running")
                            }
                            Spacer()
                            Text("\(owner.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    } icon: {
                        Image(nsImage: store.icon(for: owner.id)).resizable().frame(width: 16, height: 16)
                    }
                    .tag(Page.app(owner.id))
                    .contextMenu {
                        Button("Hide \(owner.name)") { Preferences.shared.hideApp(owner.id); store.rebuild() }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var frontmostRow: some View {
        Label {
            HStack {
                Text(store.frontmost?.localizedName ?? "App in Front").lineLimit(1)
                Spacer()
                Text("Menus").font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            if let app = store.frontmost, let icon = app.icon {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "macwindow")
            }
        }
        .tag(Page.frontmost)
    }

    private func row(_ page: Page, _ symbol: String, count: Int? = nil, tint: Color? = nil) -> some View {
        Label {
            HStack {
                Text(page.title)
                Spacer()
                if let count { Text("\(count)").foregroundStyle(tint ?? .secondary).monospacedDigit() }
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint ?? .accentColor)
        }
        .tag(page)
    }
}

/// A searchable list with an inspector.
struct ShortcutList: View {
    @State var state: WindowState
    let entries: [ShortcutEntry]
    var showOwner = true
    @State private var store = ShortcutStore.shared

    var body: some View {
        HSplitView {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: emptySymbol, description: Text(emptyText))
                } else {
                    List(selection: $state.selection) {
                        ForEach(groups, id: \.title) { group in
                            Section(group.title) {
                                ForEach(group.entries) { entry in
                                    ShortcutRow(entry: entry, showOwner: showOwner && group.mixed)
                                        .tag(entry.id)
                                        .contextMenu { menu(for: entry) }
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            if let entry = entries.first(where: { $0.id == state.selection }) ?? store.frontmostMenus.first(where: { $0.id == state.selection }) {
                ShortcutInspector(entry: entry)
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 380, maxHeight: .infinity)
            }
        }
        .searchable(text: $state.search, placement: .toolbar, prompt: "Name, app or keys (⌘⇧4)")
    }

    private var emptyTitle: String {
        if !state.search.isEmpty { return "No Matches" }
        return state.page == .conflicts ? "No Conflicts" : "No Shortcuts"
    }
    private var emptySymbol: String {
        if !state.search.isEmpty { return "magnifyingglass" }
        return state.page == .conflicts ? "checkmark.circle" : "keyboard"
    }
    private var emptyText: String {
        if !state.search.isEmpty { return "Nothing matches “\(state.search)”." }
        if state.page == .conflicts { return "No two shortcuts that ShortcutsLens can see share the same keys." }
        return store.isScanning ? "Looking for shortcuts…" : ""
    }

    struct ListGroup { var title: String; var entries: [ShortcutEntry]; var mixed: Bool }

    /// Conflicts by keys; everything else by app, then section.
    private var groups: [ListGroup] {
        if state.page == .conflicts {
            var order: [KeyCombo] = []
            var by: [KeyCombo: [ShortcutEntry]] = [:]
            for e in entries {
                if by[e.combo] == nil { order.append(e.combo) }
                by[e.combo, default: []].append(e)
            }
            return order.map { ListGroup(title: $0.display, entries: by[$0] ?? [], mixed: true) }
        }
        var order: [String] = []
        var by: [String: [ShortcutEntry]] = [:]
        for e in entries {
            let title = state.page == .all ? e.ownerName : (e.category ?? e.ownerName)
            if by[title] == nil { order.append(title) }
            by[title, default: []].append(e)
        }
        return order.map { ListGroup(title: $0, entries: by[$0] ?? [], mixed: state.page == .conflicts || state.page == .menuOverrides) }
    }

    @ViewBuilder private func menu(for entry: ShortcutEntry) -> some View {
        Button("Copy") { Actions.copy(entry) }
        Button("Copy All Shown") { Actions.copyAll(entries) }
        Divider()
        Button("Hide This Shortcut") { Preferences.shared.hide(entry); store.rebuild() }
        if entry.ownerID != ShortcutEntry.macOSOwner && entry.ownerID != ShortcutEntry.servicesOwner {
            Button("Hide Everything from \(entry.ownerName)") { Preferences.shared.hideApp(entry.ownerID); store.rebuild() }
        }
    }
}

/// The frontmost app's menu shortcuts.
struct FrontmostView: View {
    @State var state: WindowState
    @State private var store = ShortcutStore.shared

    var body: some View {
        Group {
            if !store.accessibilityTrusted {
                ContentUnavailableView {
                    Label("Allow Accessibility", systemImage: "lock.shield")
                } description: {
                    Text("To read the menus of the app you're using, ShortcutsLens needs Accessibility permission. It only reads menu names and their shortcuts, and never changes anything.")
                } actions: {
                    Button("Allow…") { MenuReader.requestAccess() }
                    Button("Open Privacy & Security") { MenuReader.openAccessibilitySettings() }
                }
            } else if store.frontmost == nil {
                ContentUnavailableView("No App in Front", systemImage: "macwindow",
                                       description: Text("Click in another app, then come back here."))
            } else if store.readingMenus && store.frontmostMenus.isEmpty {
                ProgressView("Reading \(store.frontmost?.localizedName ?? "the app")'s menus…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ShortcutList(state: state, entries: store.frontmostMenus.filter { $0.matches(state.search) }, showOwner: false)
            }
        }
        .onAppear { store.readFrontmostMenus() }
        .onChange(of: store.frontmost?.processIdentifier) { store.readFrontmostMenus() }
    }
}
