import AppKit

public struct RenderActionItem: Equatable {
    public let id: String
    public let label: String
    public let enabled: Bool

    public init(id: String, label: String, enabled: Bool) {
        self.id = id
        self.label = label
        self.enabled = enabled
    }
}

public final class ActionRingPanel: NSPanel {
    private static let panelSize = CGSize(width: 310, height: 158)
    private let ringView = ActionRingView(frame: NSRect(origin: .zero, size: panelSize))
    private let coordinateSpace: any RenderCoordinateSpace
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var keyMonitor: Any?
    private var dismissWorkItem: DispatchWorkItem?
    private var isPresented = false

    public var onAction: ((String) -> Void)?
    public var onChat: (() -> Void)?
    public var onDismiss: (() -> Void)?

    public init(coordinateSpace: (any RenderCoordinateSpace)? = nil) {
        self.coordinateSpace = coordinateSpace ?? AppKitRenderCoordinateSpace()
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(Int(CGWindowLevelForKey(.floatingWindow)) + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        worksWhenModal = true
        contentView = ringView
        ringView.onAction = { [weak self] id in
            self?.dismiss()
            self?.onAction?(id)
        }
        ringView.onChat = { [weak self] in
            self?.dismiss()
            self?.onChat?()
        }
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    public func show(
        at flippedCenter: CGPoint,
        primary: [RenderActionItem],
        extended: [RenderActionItem]
    ) {
        dismissWorkItem?.cancel()
        installMonitors()
        ringView.configure(primary: primary, extended: extended)
        let work = coordinateSpace.flippedWorkArea(containing: flippedCenter)
        let x = max(work.minX, min(flippedCenter.x - frame.width / 2, work.maxX - frame.width))
        let top = max(work.minY, min(flippedCenter.y - frame.height / 2, work.maxY - frame.height))
        setFrame(coordinateSpace.appKitRect(
            flippedTop: top,
            x: x,
            width: frame.width,
            height: frame.height), display: false)
        isPresented = true
        orderFrontRegardless()
        let item = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: item)
    }

    public func dismiss() {
        guard isPresented || isVisible else { return }
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        removeMonitors()
        ringView.dismissMoreMenu()
        orderOut(nil)
        isPresented = false
        onDismiss?()
    }

    private func installMonitors() {
        removeMonitors()
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.dismiss() }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self else { return event }
                if event.window !== self && !ringView.isMoreMenuVisible { dismiss() }
                return event
            }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { dismiss(); return nil }
            return event
        }
    }

    private func removeMonitors() {
        if let value = globalMouseMonitor { NSEvent.removeMonitor(value); globalMouseMonitor = nil }
        if let value = localMouseMonitor { NSEvent.removeMonitor(value); localMouseMonitor = nil }
        if let value = keyMonitor { NSEvent.removeMonitor(value); keyMonitor = nil }
    }
}

private final class RingButton: NSButton {
    let itemID: String?

    init(title: String, itemID: String? = nil) {
        self.itemID = itemID
        super.init(frame: .zero)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("Action ring is programmatic") }
}

private final class ActionRingView: NSView {
    var onAction: ((String) -> Void)?
    var onChat: (() -> Void)?
    private var moreMenu: NSMenu?
    private var moreMenuOpen = false
    var isMoreMenuVisible: Bool { moreMenuOpen }
    override var isFlipped: Bool { true }

    func configure(primary: [RenderActionItem], extended: [RenderActionItem]) {
        subviews.forEach { $0.removeFromSuperview() }
        moreMenu = nil
        moreMenuOpen = false
        let size = CGSize(width: 68, height: 30)
        let gap: CGFloat = 6
        let origin = CGPoint(x: 10, y: 10)
        for (index, item) in primary.enumerated() {
            let button = makeButton(item.label, itemID: item.id, index: index, size: size, gap: gap, origin: origin)
            button.isEnabled = item.enabled
            button.setAccessibilityLabel(item.label)
            button.toolTip = item.label
            button.target = self
            button.action = #selector(actionPressed(_:))
            addSubview(button)
        }
        let chat = makeButton("聊天", itemID: nil, index: primary.count, size: size, gap: gap, origin: origin)
        chat.target = self
        chat.action = #selector(chatPressed)
        chat.setAccessibilityLabel("聊天")
        addSubview(chat)
        if !extended.isEmpty {
            let more = makeButton("更多", itemID: nil, index: primary.count + 1, size: size, gap: gap, origin: origin)
            more.target = self
            more.action = #selector(morePressed(_:))
            addSubview(more)
        }
        let menu = NSMenu(title: "更多")
        for item in extended {
            let entry = NSMenuItem(title: item.label, action: #selector(extendedPressed(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = item.id
            entry.isEnabled = item.enabled
            menu.addItem(entry)
        }
        moreMenu = menu
    }

    func dismissMoreMenu() { moreMenu?.cancelTracking(); moreMenuOpen = false }

    private func makeButton(
        _ title: String,
        itemID: String?,
        index: Int,
        size: CGSize,
        gap: CGFloat,
        origin: CGPoint
    ) -> RingButton {
        let button = RingButton(title: title, itemID: itemID)
        button.frame = CGRect(
            x: origin.x + CGFloat(index % 4) * (size.width + gap),
            y: origin.y + CGFloat(index / 4) * (size.height + gap),
            width: size.width,
            height: size.height)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        return button
    }

    @objc private func actionPressed(_ sender: RingButton) {
        guard sender.isEnabled, let id = sender.itemID else { return }
        onAction?(id)
    }
    @objc private func chatPressed() { onChat?() }
    @objc private func morePressed(_ sender: NSButton) {
        guard let moreMenu else { return }
        moreMenuOpen = true
        moreMenu.popUp(positioning: nil, at: CGPoint(x: sender.frame.minX, y: sender.frame.maxY + 4), in: self)
        moreMenuOpen = false
    }
    @objc private func extendedPressed(_ sender: NSMenuItem) {
        guard sender.isEnabled, let id = sender.representedObject as? String else { return }
        onAction?(id)
    }
}
