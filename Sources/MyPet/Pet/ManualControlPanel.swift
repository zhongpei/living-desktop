import AppKit
import MyPetCombat

/// Key-window used only while the user explicitly takes control of one actor.
/// It avoids global event taps/Input Monitoring permission and releases every key on blur.
@MainActor
final class ManualControlPanel: NSPanel {
    var onInput: ((FighterInputFrame) -> Void)?
    var onExit: (() -> Void)?

    private let inputView = ManualControlView()
    private let label = NSTextField(labelWithString: "")
    private(set) var actorName = ""
    private var mappings = ManualControlMappingCatalog()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 92),
            styleMask: [.titled, .utilityWindow],
            backing: .buffered,
            defer: false)
        title = "Living Desktop · Manual Control"
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false

        let root = NSView(frame: contentView!.bounds)
        root.autoresizingMask = [.width, .height]
        label.frame = NSRect(x: 14, y: 44, width: 302, height: 34)
        label.maximumNumberOfLines = 2
        label.font = .systemFont(ofSize: 12)
        root.addSubview(label)
        inputView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        root.addSubview(inputView)
        contentView = root

        inputView.onInput = { [weak self] in self?.onInput?($0) }
        inputView.onExit = { [weak self] in self?.finish() }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: self, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.inputView.focusLost() }
        }
    }

    func setMapping(_ mapping: ManualControlMapping, for characterID: String) {
        mappings.set(mapping, for: characterID)
    }

    func begin(actorName: String, characterID: String) {
        self.actorName = actorName
        let mapping = mappings.mapping(for: characterID)
        label.stringValue = "控制：\(actorName)\n键位方案：\(mapping.id) · Esc 退出"
        inputView.beginSession(mapping: mapping)
        center()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(inputView)
    }

    func finish() {
        inputView.endSession()
        orderOut(nil)
        onExit?()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class ManualControlView: NSView {
    var onInput: ((FighterInputFrame) -> Void)?
    var onExit: (() -> Void)?
    private var session = ManualControlSession()

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onExit?(); return }
        guard let key = Self.key(for: event.keyCode) else { return }
        onInput?(session.press(key))
    }

    override func keyUp(with event: NSEvent) {
        guard let key = Self.key(for: event.keyCode) else { return }
        onInput?(session.release(key))
    }

    func beginSession(mapping: ManualControlMapping) {
        onInput?(session.begin(mapping: mapping))
    }

    func focusLost() {
        onInput?(session.focusLost())
    }

    func endSession() {
        onInput?(session.end())
    }

    private static func key(for keyCode: UInt16) -> KeyboardControlKey? {
        let keys: [UInt16: KeyboardControlKey] = [
            123: .arrowLeft, 124: .arrowRight,
            126: .arrowUp, 125: .arrowDown,
            6: .keyZ, 7: .keyX, 8: .keyC,
            0: .keyA, 1: .keyS, 2: .keyD,
        ]
        return keys[keyCode]
    }
}
