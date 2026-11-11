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

    /// Pages that show a list of shortcuts, which the Filter menu narrows.
    var isList: Bool {
        switch self {
        case .keyboard, .free, .conflicts: false
        default: true
        }
    }
}

@Observable
@MainActor
final class WindowState {
    var page: Page = .all
    var search = ""
    var selection: ShortcutEntry.ID?
    var columns: NavigationSplitViewVisibility = .all
    var showInspector = UserDefaults.standard.object(forKey: "showInspector") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showInspector, forKey: "showInspector") }
    }
    /// Filter menu choices for this window; turned-off shortcuts are a setting (`showDisabled`).
    var onlyConflicts = false
    var onlyRunning = false
    // Keyboard Map and Find a Free Shortcut, kept here so the inspector can show them.
    var keyboardModifiers: Modifiers = [.command]
    var pickedKey: Int?
    var includeMenus = false
    var freeCheck: KeyCombo?
    /// What's chosen in Check a Shortcut: the modifier buttons and the typed key.
    var checkModifiers: Modifiers = []
    var checkKey = ""

    var sidebarShown: Bool { columns != .detailOnly }
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

    func toggleSidebar() {
        withAnimation { state.columns = state.sidebarShown ? .detailOnly : .all }
    }

    func toggleInspector() {
        withAnimation { state.showInspector.toggle() }
    }

    func rescan() {
        let store = ShortcutStore.shared
        store.refresh()
        if state.page == .frontmost { store.readFrontmostMenus() }
    }

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
        NavigationSplitView(columnVisibility: $state.columns) {
            Sidebar(state: state)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            detail
                .navigationTitle(state.page.title)
                .navigationSubtitle(subtitle)
                // The hosted split view doesn't hand its title to the window.
                .onChange(of: state.page, initial: true) { MainWindow.shared.setTitle(state.page.title) }
                .toolbar { toolbar }
        }
        .inspector(isPresented: $state.showInspector) {
            InspectorPane(state: state)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
                .toolbar {
                    ToolbarSpacer(.flexible)
                    ToolbarItem(placement: .primaryAction) {
                        Button { MainWindow.shared.toggleInspector() } label: {
                            Label(state.showInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing")
                        }
                        .help("Show or hide the inspector (⌃⌘I)")
                    }
                }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if store.isScanning { ProgressView().controlSize(.small) }
            Button { MainWindow.shared.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                .help("Look for shortcuts again (⌘R)")
            Menu {
                Toggle("Show Turned-Off Shortcuts", isOn: $prefs.showDisabled)
                Divider()
                Toggle("Only Conflicts", isOn: $state.onlyConflicts)
                Toggle("Only Apps That Are Running", isOn: $state.onlyRunning)
            } label: {
                Label("Filter", systemImage: filtering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
            }
            .menuIndicator(.hidden)
            .help("Choose which shortcuts the lists show")
            Button { QuickView.shared.show() } label: { Label("Quick View", systemImage: "rectangle.on.rectangle") }
                .help("Open the Quick View" + (prefs.quickViewHotKey.map { " (\($0.display))" } ?? ""))
        }
    }

    /// A filter that narrows the lists is on (turned-off shortcuts are a standing setting).
    private var filtering: Bool { state.onlyConflicts || state.onlyRunning }

    private var subtitle: String {
        switch state.page {
        case .keyboard:
            let taken = Set(store.globalVisible.filter { $0.enabled && $0.combo.modifiers == state.keyboardModifiers }.compactMap(\.combo.keyCode))
            return "\(state.keyboardModifiers.isEmpty ? "No modifiers" : state.keyboardModifiers.name): \(taken.count) key\(taken.count == 1 ? "" : "s") taken"
        case .free: return "Click a free shortcut to copy it"
        case .frontmost: return store.frontmost?.localizedName ?? ""
        case .conflicts:
            let sets = Set(entries.map(\.combo)).count
            return "\(sets) set\(sets == 1 ? "" : "s") of keys, \(entries.count) shortcut\(entries.count == 1 ? "" : "s")"
        default:
            var parts = ["\(entries.count) shortcut\(entries.count == 1 ? "" : "s")"]
            if !prefs.showDisabled {
                let off = baseEntries.filter { !$0.enabled }.count
                if off > 0 { parts.append("\(off) turned off, hidden") }
            }
            if state.onlyConflicts { parts.append("only conflicts") }
            if state.onlyRunning { parts.append("only running apps") }
            return parts.joined(separator: " · ")
        }
    }

    @ViewBuilder private var detail: some View {
        switch state.page {
        case .keyboard: KeyboardMapView(state: state)
        case .free: FreeShortcutsView(state: state)
        case .frontmost: FrontmostView(state: state, filter: filter)
        case .conflicts: ConflictsView(state: state, entries: entries)
        default: ShortcutList(state: state, entries: entries, showOwner: showOwner)
        }
    }

    private var showOwner: Bool {
        switch state.page {
        case .app, .macOS, .services: false
        default: true
        }
    }

    /// The page's shortcuts before search and the Filter menu, counting turned-off ones.
    private var baseEntries: [ShortcutEntry] {
        let all = store.all.filter { !store.isHidden($0) }
        switch state.page {
        case .all: return all
        case .macOS: return all.filter { $0.ownerID == ShortcutEntry.macOSOwner }
        case .services: return all.filter { $0.source == .services }
        case .menuOverrides: return all.filter { $0.source == .menuOverride }
        case .app(let id): return all.filter { $0.ownerID == id }
        default: return []
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
        return filter(list).filter { $0.matches(state.search) }
    }

    /// The Filter menu's narrowing, for list pages.
    private func filter(_ list: [ShortcutEntry]) -> [ShortcutEntry] {
        guard state.page.isList else { return list }
        var list = list
        if state.onlyConflicts { list = list.filter { !store.partners(of: $0).isEmpty } }
        if state.onlyRunning {
            list = list.filter { !($0.source.needsApp && !store.isRunning($0.ownerID)) }
        }
        return list
    }
}

struct Sidebar: View {
    @State var state: WindowState
    @State private var store = ShortcutStore.shared

    var body: some View {
        List(selection: Binding<Page?>(get: { state.page }, set: { if let p = $0 { state.page = p; state.selection = nil } })) {
            Section {
                row(.all, "command", count: store.visible.count)
                // Counted by keys, as the menu counts them.
                row(.conflicts, "exclamationmark.triangle", count: store.conflicts.count,
                    tint: store.conflicts.isEmpty ? nil : .orange)
                row(.keyboard, "keyboard")
                row(.free, "magnifyingglass")
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

    /// Always "App in Front", so it matches the View menu; the app's name sits on the right.
    private var frontmostRow: some View {
        Label {
            HStack {
                Text(Page.frontmost.title).lineLimit(1)
                Spacer()
                if let name = store.frontmost?.localizedName {
                    Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
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

/// A searchable list of shortcuts; the selected one shows in the inspector.
struct ShortcutList: View {
    @State var state: WindowState
    let entries: [ShortcutEntry]
    var showOwner = true
    @State private var store = ShortcutStore.shared

    var body: some View {
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
                                    .contextMenu { EntryMenu(entry: entry, shown: entries) }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .onCopyCommand { Actions.providers(for: state.selection, in: entries) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .searchable(text: $state.search, placement: .toolbar, prompt: "Name, app or keys (⌘⇧4)")
    }

    private var emptyTitle: String {
        if !state.search.isEmpty { return "No Matches" }
        return "No Shortcuts"
    }
    private var emptySymbol: String {
        state.search.isEmpty ? "keyboard" : "magnifyingglass"
    }
    private var emptyText: String {
        if !state.search.isEmpty { return "Nothing matches “\(state.search)”." }
        if store.isScanning { return "Looking for shortcuts…" }
        if state.onlyConflicts || state.onlyRunning { return "Nothing here matches the Filter menu's choices." }
        return ""
    }

    struct ListGroup { var title: String; var entries: [ShortcutEntry]; var mixed: Bool }

    /// By app, then section.
    private var groups: [ListGroup] {
        var order: [String] = []
        var by: [String: [ShortcutEntry]] = [:]
        for e in entries {
            let title = state.page == .all ? e.ownerName : (e.category ?? e.ownerName)
            if by[title] == nil { order.append(title) }
            by[title, default: []].append(e)
        }
        return order.map { ListGroup(title: $0, entries: by[$0] ?? [], mixed: state.page == .menuOverrides) }
    }
}

/// The right-click menu of a shortcut, in every list.
struct EntryMenu: View {
    let entry: ShortcutEntry
    /// The shortcuts the page shows, for Copy All Shown.
    let shown: [ShortcutEntry]
    @State private var store = ShortcutStore.shared

    var body: some View {
        Button("Copy") { Actions.copy(entry) }
        Button("Copy All Shown") { Actions.copyAll(shown) }
        Divider()
        Button("Hide This Shortcut") { Preferences.shared.hide(entry); store.rebuild() }
        if entry.ownerID != ShortcutEntry.macOSOwner && entry.ownerID != ShortcutEntry.servicesOwner {
            Button("Hide Everything from \(entry.ownerName)") { Preferences.shared.hideApp(entry.ownerID); store.rebuild() }
        }
    }
}

/// Conflicts as one card per set of keys: the keys once, then each shortcut that wants them.
struct ConflictsView: View {
    @State var state: WindowState
    let entries: [ShortcutEntry]
    @State private var store = ShortcutStore.shared

    private struct Group: Identifiable {
        let combo: KeyCombo
        let entries: [ShortcutEntry]
        var id: KeyCombo { combo }
    }

    private var groups: [Group] {
        var order: [KeyCombo] = []
        var by: [KeyCombo: [ShortcutEntry]] = [:]
        for e in entries {
            if by[e.combo] == nil { order.append(e.combo) }
            by[e.combo, default: []].append(e)
        }
        return order.map { Group(combo: $0, entries: by[$0] ?? []) }
    }

    var body: some View {
        SwiftUI.Group {
            if entries.isEmpty {
                ContentUnavailableView(state.search.isEmpty ? "No Conflicts" : "No Matches",
                                       systemImage: state.search.isEmpty ? "checkmark.circle" : "magnifyingglass",
                                       description: Text(state.search.isEmpty
                                                         ? "No two shortcuts that ShortcutsLens can see share the same keys."
                                                         : "Nothing matches “\(state.search)”."))
            } else {
                List(selection: $state.selection) {
                    Text("When two apps want the same keys, only one of them gets them: usually whichever registered them first. Change one shortcut in each card so both work.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowSeparator(.hidden)
                        .selectionDisabled()
                    ForEach(groups) { group in
                        Section {
                            header(group)
                                .listRowBackground(CardBackground(top: true, bottom: false))
                                .listRowSeparator(.hidden)
                                .selectionDisabled()
                            ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                                ConflictRow(entry: entry)
                                    .tag(entry.id)
                                    .contextMenu { EntryMenu(entry: entry, shown: entries) }
                                    .listRowBackground(CardBackground(top: false, bottom: index == group.entries.count - 1))
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .onCopyCommand { Actions.providers(for: state.selection, in: entries) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .searchable(text: $state.search, placement: .toolbar, prompt: "Name, app or keys (⌘⇧4)")
    }

    private func header(_ group: Group) -> some View {
        let owners = Set(group.entries.map(\.ownerID)).count
        return HStack(spacing: 12) {
            Keycaps(combo: group.combo)
            Text(group.combo.spoken).fontWeight(.semibold)
            Spacer()
            Label(owners > 1 ? "\(owners) apps" : "\(group.entries.count) shortcuts", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
        }
        .padding(.vertical, 6)
    }
}

/// One shortcut in a conflict card, with the button that leads to where it's changed.
struct ConflictRow: View {
    let entry: ShortcutEntry
    @State private var store = ShortcutStore.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: store.icon(for: entry.ownerID)).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).lineLimit(1)
                Text("\(entry.ownerName) · \(entry.source.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let action = Actions.changeAction(for: entry) {
                Button(action.title, action: action.run).controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

/// The rounded card behind a group of list rows.
struct CardBackground: View {
    let top: Bool
    let bottom: Bool

    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: top ? 12 : 0, bottomLeadingRadius: bottom ? 12 : 0,
                               bottomTrailingRadius: bottom ? 12 : 0, topTrailingRadius: top ? 12 : 0, style: .continuous)
            .fill(Color.primary.opacity(0.045))
            .padding(.horizontal, 10)
    }
}

/// The inspector column: the selected shortcut, the clicked key, or the shortcut being tested.
struct InspectorPane: View {
    @State var state: WindowState
    @State private var store = ShortcutStore.shared

    var body: some View {
        switch state.page {
        case .keyboard:
            if let key = state.pickedKey { KeyInspector(state: state, keyCode: key) } else {
                ContentUnavailableView("No Key Chosen", systemImage: "keyboard",
                                       description: Text("Click a key on the map to see everything on it, with any modifiers."))
            }
        case .free:
            if let combo = state.freeCheck { FreeInspector(combo: combo) } else {
                ContentUnavailableView("Nothing to Test", systemImage: "magnifyingglass",
                                       description: Text("Press a shortcut in the box to see whether anything uses it."))
            }
        default:
            if let entry = selected { ShortcutInspector(entry: entry) } else {
                ContentUnavailableView("No Selection", systemImage: "command",
                                       description: Text("Click a shortcut to see where it came from and what else uses its keys."))
            }
        }
    }

    private var selected: ShortcutEntry? {
        guard let id = state.selection else { return nil }
        return store.all.first { $0.id == id } ?? store.frontmostMenus.first { $0.id == id }
    }
}

/// Everything on one key of the Keyboard Map, with any modifiers.
struct KeyInspector: View {
    @State var state: WindowState
    let keyCode: Int
    @State private var store = ShortcutStore.shared

    var body: some View {
        let onKey = used.filter { $0.combo.keyCode == keyCode }.sorted { $0.combo < $1.combo }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Keycaps(combo: KeyCombo(keyCode: keyCode, modifiers: []), size: .large)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Everything on \(KeyNames.spokenName(for: keyCode))").font(.title3.weight(.semibold))
                        Text("With any modifiers").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if onKey.isEmpty {
                    Text("No system-wide shortcut uses this key.").foregroundStyle(.secondary)
                } else {
                    ForEach(onKey) { entry in
                        Divider()
                        ShortcutRow(entry: entry).contextMenu { EntryMenu(entry: entry, shown: onKey) }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var used: [ShortcutEntry] {
        var list = store.globalVisible.filter(\.enabled)
        if state.includeMenus { list += store.frontmostMenus.filter(\.enabled) }
        return list
    }
}

/// The shortcut being tested on Find a Free Shortcut.
struct FreeInspector: View {
    let combo: KeyCombo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Keycaps(combo: combo, size: .large)
                Text(combo.spoken).foregroundStyle(.secondary).textSelection(.enabled)
                ComboUsage(combo: combo, offersChanges: true)
                Button("Copy") { Actions.copy(combo.display) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The frontmost app's menu shortcuts.
struct FrontmostView: View {
    @State var state: WindowState
    let filter: ([ShortcutEntry]) -> [ShortcutEntry]
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
                ShortcutList(state: state, entries: filter(store.frontmostMenus).filter { $0.matches(state.search) }, showOwner: false)
            }
        }
        .onAppear { store.readFrontmostMenus() }
        .onChange(of: store.frontmost?.processIdentifier) { store.readFrontmostMenus() }
    }
}
