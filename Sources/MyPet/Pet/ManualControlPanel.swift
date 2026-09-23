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
            Task { @MainActor in self?.inputView.releaseAll() }
        }
    }

    func begin(actorName: String) {
        self.actorName = actorName
        label.stringValue = "控制：\(actorName)\n方向键移动/跳/蹲 · Z X C / A S D 攻击 · Esc 退出"
        center()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(inputView)
    }

    func finish() {
        inputView.releaseAll()
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
    private var pressed = Set<UInt16>()

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onExit?(); return }
        pressed.insert(event.keyCode)
        emit()
    }

    override func keyUp(with event: NSEvent) {
        pressed.remove(event.keyCode)
        emit()
    }

    func releaseAll() {
        guard !pressed.isEmpty else { return }
        pressed.removeAll()
        emit()
    }

    private func emit() {
        let chars: [UInt16: CombatButton] = [
            6: .x, 7: .y, 8: .z, // physical Z X C -> logical X Y Z
            0: .a, 1: .s, 2: .d  // a s d
        ]
        var buttons = Set<CombatButton>()
        for (key, button) in chars where pressed.contains(key) { buttons.insert(button) }
        onInput?(FighterInputFrame(
            left: pressed.contains(123),
            right: pressed.contains(124),
            up: pressed.contains(126),
            down: pressed.contains(125),
            buttons: buttons))
    }
}
