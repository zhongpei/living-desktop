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
    private var mappings: ManualControlMappingCatalog
    private var pendingMappings: ManualControlMappingCatalog?
    private var activeCharacterID: String?

    init(mappings: ManualControlMappingCatalog = ManualControlMappingCatalog()) {
        self.mappings = mappings
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
        inputView.onAllKeysReleased = { [weak self] in self?.commitPendingMappingsIfPossible() }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: self, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.inputView.focusLost() }
        }
    }

    func applyMappings(_ mappings: ManualControlMappingCatalog) {
        guard isVisible else {
            self.mappings = mappings
            return
        }
        pendingMappings = mappings
        commitPendingMappingsIfPossible()
    }

    func begin(actorName: String, characterID: String) {
        self.actorName = actorName
        activeCharacterID = characterID
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
        if let pendingMappings {
            mappings = pendingMappings
            self.pendingMappings = nil
        }
        activeCharacterID = nil
        onExit?()
    }

    private func commitPendingMappingsIfPossible() {
        guard let pendingMappings, let activeCharacterID,
              inputView.applyMappingIfIdle(
                pendingMappings.mapping(for: activeCharacterID)) else { return }
        mappings = pendingMappings
        self.pendingMappings = nil
        label.stringValue = "控制：\(actorName)\n键位方案：\(mappings.mapping(for: activeCharacterID).id) · Esc 退出"
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class ManualControlView: NSView {
    var onInput: ((FighterInputFrame) -> Void)?
    var onExit: (() -> Void)?
    var onAllKeysReleased: (() -> Void)?
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
        if session.pressedKeys.isEmpty { onAllKeysReleased?() }
    }

    func beginSession(mapping: ManualControlMapping) {
        onInput?(session.begin(mapping: mapping))
    }

    func focusLost() {
        onInput?(session.focusLost())
        onAllKeysReleased?()
    }

    func endSession() {
        onInput?(session.end())
    }

    func applyMappingIfIdle(_ mapping: ManualControlMapping) -> Bool {
        session.applyMappingIfIdle(mapping)
    }

    private static func key(for keyCode: UInt16) -> KeyboardControlKey? {
        let keys: [UInt16: KeyboardControlKey] = [
            123: .arrowLeft, 124: .arrowRight,
            126: .arrowUp, 125: .arrowDown,
            6: .keyZ, 7: .keyX, 8: .keyC,
            0: .keyA, 1: .keyS, 2: .keyD,
            12: .keyQ, 13: .keyW, 14: .keyE, 15: .keyR,
        ]
        return keys[keyCode]
    }
}
