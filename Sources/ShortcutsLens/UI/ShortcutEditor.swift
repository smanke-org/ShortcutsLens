import AppKit
import Carbon.HIToolbox
import ShortcutsLensKit
import SwiftUI

/// ShortcutsLens's own shortcut box (the Quick View shortcut). Clicking it opens an editor
/// under it with the same modifier buttons and key field as Check a Shortcut; pressing the
/// keys while it's open fills them in too. `ownID` is the entry this shortcut shows up as,
/// so it isn't listed as taking its own keys.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var combo: KeyCombo?
    var ownID: String? = nil
    var placeholder = "Click to set"

    func makeNSView(context: Context) -> RecorderButton {
        let view = RecorderButton()
        // Keep its own width rather than stretching across a row.
        view.setContentHuggingPriority(.required, for: .horizontal)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: RecorderButton, context: Context) {
        view.onChange = { combo = $0 }
        view.ownID = ownID
        view.placeholder = placeholder
        view.combo = combo
    }

    final class RecorderButton: NSButton {
        var onChange: ((KeyCombo?) -> Void)?
        var ownID: String?
        var placeholder = "Click to set" { didSet { refresh() } }
        var combo: KeyCombo? { didSet { refresh() } }
        private var popover: NSPopover?
        private var model: ShortcutEditorModel?
        private var monitor: Any?

        override init(frame: NSRect) {
            super.init(frame: frame)
            bezelStyle = .rounded
            target = self
            action = #selector(open)
            refresh()
        }

        required init?(coder: NSCoder) { fatalError() }

        override var intrinsicContentSize: NSSize { NSSize(width: 140, height: super.intrinsicContentSize.height) }

        private func refresh() {
            title = popover != nil ? "Set a shortcut…" : (combo?.display ?? placeholder)
            setAccessibilityLabel(popover != nil ? "Set a shortcut" : (combo?.spoken ?? placeholder))
        }

        @objc func open() {
            guard popover == nil, window != nil else { popover?.close(); return }
            // The current shortcut must not fire while new keys are pressed.
            HotKeyCenter.shared.pause()
            let model = ShortcutEditorModel(combo: combo, ownID: ownID)
            model.finish = { [weak self] result in self?.finish(result) }
            self.model = model
            let host = NSHostingController(rootView: ShortcutEditor(model: model))
            host.sizingOptions = [.preferredContentSize]
            let popover = NSPopover()
            popover.behavior = .transient
            #if DEBUG
            // The editor test runs while other things click the screen; keep it open for that.
            if ProcessInfo.processInfo.environment["SHORTCUTSLENS_DEBUG_EDITOR"] != nil { popover.behavior = .applicationDefined }
            #endif
            popover.contentViewController = host
            popover.contentSize = host.view.fittingSize
            popover.delegate = PopoverCloser.shared
            PopoverCloser.shared.onClose[ObjectIdentifier(popover)] = { [weak self] in self?.closed() }
            self.popover = popover
            refresh()
            popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak model] event in
                guard let model else { return event }
                return model.handle(event) ? nil : event
            }
        }

        private func finish(_ result: ShortcutEditorModel.Result) {
            if case .set(let new) = result {
                combo = new
                onChange?(new)
            }
            // Tidy up now rather than when the close animation ends, so the shortcut is back
            // on and the box can be opened again straight away.
            let closing = popover
            closed()
            closing?.close()
        }

        private func closed() {
            // Once only: Set, Clear and Cancel tidy up at once, before the close message comes.
            guard popover != nil else { return }
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if let popover { PopoverCloser.shared.onClose[ObjectIdentifier(popover)] = nil }
            popover = nil
            model = nil
            refresh()
            // The binding writes Preferences synchronously, so this registers the new keys.
            HotKeyCenter.shared.resume()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { popover?.close() }
            super.viewWillMove(toWindow: newWindow)
        }

        #if DEBUG
        var debugModel: ShortcutEditorModel? { model }
        var debugPopoverView: NSView? { popover?.contentViewController?.view }
        var debugTitle: String { title }
        #endif
    }
}

/// NSPopover's delegate is weak; one shared object tells each button its popover closed.
@MainActor private final class PopoverCloser: NSObject, NSPopoverDelegate {
    static let shared = PopoverCloser()
    var onClose: [ObjectIdentifier: () -> Void] = [:]
    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover else { return }
        onClose[ObjectIdentifier(popover)]?()
    }
}

@MainActor final class ShortcutEditorModel: ObservableObject {
    enum Result { case set(KeyCombo?), cancel }

    @Published var modifiers: Modifiers = []
    /// What's in the key box: one typed character or a key's name.
    @Published var key = ""
    /// What ComboPicker reads from the buttons and the key box.
    @Published var combo: KeyCombo?
    @Published var showHint = false

    let original: KeyCombo?
    let ownID: String?
    var finish: ((Result) -> Void)?
    private var modifiersDown = false
    private var sawKey = false

    static let choices: [Modifiers] = [.control, .option, .shift, .command]

    init(combo: KeyCombo?, ownID: String?) {
        original = combo
        self.ownID = ownID
        if let combo, let code = combo.keyCode {
            modifiers = combo.modifiers.subtracting(.function)
            key = KeyNames.name(for: code)
            self.combo = combo
        }
    }

    /// Why Set is off, when something is in the key box.
    var problem: String? {
        let typed = key.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return nil }
        guard let combo, let code = combo.keyCode else { return "ShortcutsLens can't find “\(typed)” on this keyboard." }
        if !KeyNames.impliesFunction(code), combo.modifiers.intersection([.control, .option, .command]).isEmpty {
            return "Add ⌃, ⌥ or ⌘. Only F-keys can be used on their own."
        }
        return nil
    }

    var canSet: Bool { combo?.keyCode != nil && problem == nil }

    /// A key press while the editor is open. True when it was used.
    func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.type == .flagsChanged {
            // A shortcut another app holds never arrives: the modifiers go down and up with
            // no key between them.
            let held = !flags.intersection([.command, .option, .control]).isEmpty
            if held && !modifiersDown { modifiersDown = true; sawKey = false }
            else if !held && modifiersDown { modifiersDown = false; if !sawKey { showHint = true } }
            return false
        }
        sawKey = true
        let code = Int(event.keyCode)
        if code == kVK_Escape && flags.isEmpty { finish?(.cancel); return true }
        if (code == kVK_Return || code == kVK_ANSI_KeypadEnter) && flags.isEmpty {
            if canSet { finish?(.set(combo)) }
            return true
        }
        // With ⌃ ⌥ or ⌘ held, or an F-key, it's the whole shortcut; plain typing goes to the key box.
        guard !flags.intersection([.command, .option, .control]).isEmpty || KeyNames.impliesFunction(code) else { return false }
        press(code, Modifiers(cocoa: Int(flags.rawValue)))
        return true
    }

    /// Fills in a shortcut as if it were pressed.
    func press(_ code: Int, _ mods: Modifiers) {
        modifiers = mods.subtracting(.function)
        key = KeyNames.name(for: code)
        combo = KeyCombo(keyCode: code, modifiers: modifiers)
        showHint = false
    }
}

struct ShortcutEditor: View {
    @ObservedObject var model: ShortcutEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ComboPicker(modifiers: $model.modifiers, key: $model.key, combo: $model.combo, choices: ShortcutEditorModel.choices)

            Group {
                if let combo = model.combo, combo.keyCode != nil {
                    Keycaps(combo: combo, size: .large)
                } else {
                    Text("No shortcut").font(.title3).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 34)

            if let problem = model.problem {
                note(problem, "exclamationmark.triangle")
            } else if let combo = model.combo, combo.keyCode != nil {
                // Who else uses these keys, from everything ShortcutsLens has read: a warning, not a block.
                ComboUsage(combo: combo, ignoring: model.ownID)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.showHint {
                note("Nothing came through. If you pressed a shortcut, another app is using those keys. Press different keys, or set them with the buttons above.", "info.circle")
            }
            Text("Or press the shortcut now.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button("Clear") { model.finish?(.set(nil)) }
                    .disabled(model.original == nil)
                    .help("Turn the shortcut off")
                Spacer()
                Button("Cancel") { model.finish?(.cancel) }
                Button("Set") { model.finish?(.set(model.combo)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSet)
            }
        }
        .padding(16)
        .frame(width: Self.width)
    }

    /// As wide as the buttons and key box in one row; the notes wrap to fit.
    static let width: CGFloat = {
        let picker = NSHostingView(rootView: ComboPicker(modifiers: .constant([]), key: .constant(""), combo: .constant(nil),
                                                         choices: ShortcutEditorModel.choices))
        return ceil(picker.fittingSize.width) + 32
    }()

    private func note(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
