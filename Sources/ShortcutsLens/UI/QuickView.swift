import AppKit
import Observation
import ShortcutsLensKit
import SwiftUI

/// A floating cheat sheet over the app you're in: its menu shortcuts and every system-wide
/// one. The Quick View shortcut opens it for searching (ShortcutsLens comes forward so you can
/// type, and hands the app back on close); holding ⌘ shows it until you let go, without
/// taking the focus.
@Observable
@MainActor
final class QuickView: NSObject, NSWindowDelegate {
    static let shared = QuickView()

    enum Tab: Hashable { case app, system, conflicts }

    var tab: Tab = .app
    var search = ""
    private(set) var interactive = false
    private(set) var isShown = false

    @ObservationIgnored private var panel: QuickViewPanel?
    /// The app to hand the focus back to.
    @ObservationIgnored private var returnTo: NSRunningApplication?

    func toggle() {
        isShown && interactive ? close() : show()
    }

    func show() {
        prepare()
        interactive = true
        let front = NSWorkspace.shared.frontmostApplication
        returnTo = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        present()
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    /// While ⌘ is held: no focus, gone on release.
    func peek() {
        guard !isShown else { return }
        prepare()
        interactive = false
        present()
        panel?.orderFrontRegardless()
    }

    func endPeek() {
        if !interactive { close() }
    }

    func close() {
        guard isShown else { return }
        isShown = false
        panel?.orderOut(nil)
        if interactive, let app = returnTo, !app.isTerminated, !MainWindow.shared.isVisible || NSApp.keyWindow == nil {
            app.activate()
        }
        returnTo = nil
        interactive = false
    }

    private func prepare() {
        search = ""
        let store = ShortcutStore.shared
        store.readFrontmostMenus()
        tab = Preferences.shared.quickViewStartsOn == .frontmostApp && store.accessibilityTrusted && store.frontmost != nil ? .app : .system
    }

    private func present() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(980, visible.width - 80), height: min(640, visible.height - 80))
        // Off screen first: macOS 27 ignores a new frame for a window that's already showing.
        panel.orderOut(nil)
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height),
                       display: false)
        isShown = true
    }

    private func makePanel() -> QuickViewPanel {
        let panel = QuickViewPanel(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        let hosting = NSHostingView(rootView: QuickViewContent(view: self))
        hosting.sizingOptions = []
        panel.contentView = hosting
        AppAppearance.followSystem(panel)
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking anywhere else closes it, as a menu would.
        if interactive { close() }
    }

    #if DEBUG
    var debugPanel: NSWindow? { panel }
    #endif
}

final class QuickViewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { QuickView.shared.close() }
    }
}

struct QuickViewContent: View {
    @State var view: QuickView
    @State private var store = ShortcutStore.shared
    @FocusState private var searchFocused: Bool

    private var entries: [ShortcutEntry] {
        let list: [ShortcutEntry]
        switch view.tab {
        case .app: list = store.frontmostMenus.filter(\.enabled)
        case .system: list = store.globalVisible.filter(\.enabled)
        case .conflicts: list = store.globalVisible.filter { !store.partners(of: $0).isEmpty }.sorted { $0.combo < $1.combo }
        }
        return list.filter { $0.matches(view.search) }
    }

    private var sections: [(title: String, entries: [ShortcutEntry])] {
        var order: [String] = []
        var by: [String: [ShortcutEntry]] = [:]
        for e in entries {
            let title = view.tab == .app ? (e.category ?? "Menus") : view.tab == .conflicts ? e.combo.display : e.ownerName
            if by[title] == nil { order.append(title) }
            by[title, default: []].append(e)
        }
        return order.map { ($0, by[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            content
            Divider().opacity(0.5)
            footer
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onChange(of: view.isShown) { if view.isShown && view.interactive { searchFocused = true } }
        .onAppear { if view.interactive { searchFocused = true } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: $view.tab) {
                Text(store.frontmost?.localizedName ?? "App in Front").tag(QuickView.Tab.app)
                Text("System-wide").tag(QuickView.Tab.system)
                Text("Conflicts\(store.conflicts.isEmpty ? "" : " (\(store.conflicts.count))")").tag(QuickView.Tab.conflicts)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 440)
            .background { tabKeys }
            Spacer()
            if view.interactive {
                TextField("Search", text: $view.search, prompt: Text("Search names or keys"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .focused($searchFocused)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    /// ⌘1, ⌘2 and ⌘3 switch tabs, as the footer says.
    private var tabKeys: some View {
        ZStack {
            Button("") { view.tab = .app }.keyboardShortcut("1")
            Button("") { view.tab = .system }.keyboardShortcut("2")
            Button("") { view.tab = .conflicts }.keyboardShortcut("3")
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        if view.tab == .app && !store.accessibilityTrusted {
            ContentUnavailableView {
                Label("Allow Accessibility to see this app's menus", systemImage: "lock.shield")
            } actions: {
                Button("Allow…") { view.close(); MenuReader.requestAccess() }
            }
            .frame(maxHeight: .infinity)
        } else if entries.isEmpty {
            ContentUnavailableView(store.readingMenus ? "Reading menus…" : "Nothing Here",
                                   systemImage: view.tab == .conflicts ? "checkmark.circle" : "keyboard",
                                   description: Text(view.tab == .conflicts && view.search.isEmpty ? "No two shortcuts share keys." : ""))
                .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                HStack(alignment: .top, spacing: 24) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(column, id: \.title) { section in sectionView(section) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(18)
            }
        }
    }

    /// Sections dealt into three columns of about equal height, each to the shortest so far.
    private var columns: [[(title: String, entries: [ShortcutEntry])]] {
        var columns: [[(title: String, entries: [ShortcutEntry])]] = [[], [], []]
        var heights = [0, 0, 0]
        for section in sections {
            let i = heights.firstIndex(of: heights.min() ?? 0) ?? 0
            columns[i].append(section)
            heights[i] += section.entries.count + 2
        }
        return columns
    }

    private func sectionView(_ section: (title: String, entries: [ShortcutEntry])) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(section.title).font(.headline).lineLimit(1)
            ForEach(section.entries) { entry in
                let conflict = !store.partners(of: entry).isEmpty
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    // One size and weight for every shortcut, right-aligned so the names line up.
                    Text("\(conflict ? Text(Image(systemName: "exclamationmark.triangle.fill")) : Text(verbatim: ""))\(conflict ? " " : "")\(KeyText.text(entry.combo.display))")
                        .font(.system(size: 13, weight: .medium))
                        .tracking(1)
                        .lineLimit(1)
                        .frame(width: 104, alignment: .trailing)
                        .foregroundStyle(conflict ? Color.orange : Color.secondary)
                    Text(view.tab == .conflicts ? "\(entry.ownerName): \(entry.title)" : entry.title)
                        .lineLimit(1)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if view.interactive {
                hint(["Esc"], "closes")
                if let key = Preferences.shared.quickViewHotKey { hint([key.display], "opens and closes") }
                hint(["⌘1", "⌘2", "⌘3"], "switch tabs")
            } else {
                Text("Let go of ⌘ to close").foregroundStyle(.secondary)
            }
            Spacer()
            if view.interactive {
                Button("Open ShortcutsLens") { view.close(); MainWindow.shared.show() }
                    .buttonStyle(.link)
            }
        }
        .font(.caption)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    private func hint(_ keys: [String], _ what: String) -> some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { key in
                KeyText.text(key).fontWeight(.medium)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
            }
            Text(what).foregroundStyle(.secondary)
        }
    }
}
