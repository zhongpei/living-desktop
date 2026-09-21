import AppKit

/// 角色右键操作环。
///
/// 一级没有“动作”父按钮：常见语义动作全部直接可点；中心只保留“聊天”
/// 和“更多”。“更多”使用原生 NSMenu 承载低频扩展动作，避免把常用动作
/// 藏在第二次点击里。
final class ActionRingPanel: NSPanel {

    private static let size = CGSize(width: 310, height: 158)
    private let ringView = ActionRingView(
        frame: NSRect(origin: .zero, size: ActionRingPanel.size))
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var keyMonitor: Any?
    private var dismissWorkItem: DispatchWorkItem?
    private var isPresented = false

    var onAction: ((ActionIntent) -> Void)?
    var onChat: (() -> Void)?
    var onDismiss: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(Int(CGWindowLevelForKey(.floatingWindow)) + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        worksWhenModal = true
        contentView = ringView

        ringView.onAction = { [weak self] intent in
            guard let self else { return }
            dismiss()
            onAction?(intent)
        }
        ringView.onChat = { [weak self] in
            guard let self else { return }
            dismiss()
            onChat?()
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 在翻转世界坐标中显示，并把整个操作环限制在当前屏幕工作区内。
    func show(at flippedCenter: CGPoint,
              primary: [ActionCatalog.MenuItem],
              extended: [ActionCatalog.MenuItem],
              available: Set<String>) {
        dismissWorkItem?.cancel()
        installMonitors()
        ringView.configure(primary: primary, extended: extended, available: available)

        let width = frame.width
        let height = frame.height
        let work = Screens.workBox(containing: flippedCenter)
        let x = max(work.left, min(flippedCenter.x - width / 2, work.right - width))
        let top = max(work.top, min(flippedCenter.y - height / 2, work.bottom - height))
        setFrame(Screens.appKitRect(flippedTop: top, x: x, width: width, height: height), display: false)
        isPresented = true
        orderFrontRegardless()

        let workItem = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: workItem)
    }

    func dismiss() {
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
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.dismiss()
            }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self else { return event }
                if event.window !== self && !ringView.isMoreMenuVisible {
                    dismiss()
                }
                return event
            }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Escape
                dismiss()
                return nil
            }
            return event
        }
    }

    private func removeMonitors() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

private final class RingButton: NSButton {
    let intent: ActionIntent?

    init(title: String, intent: ActionIntent? = nil) {
        self.intent = intent
        super.init(frame: .zero)
        self.title = title
    }

    required init?(coder: NSCoder) {
        fatalError("环形菜单按钮只在代码里构建")
    }
}

private final class ActionRingView: NSView {

    var onAction: ((ActionIntent) -> Void)?
    var onChat: (() -> Void)?

    private var moreMenu: NSMenu?
    private var moreMenuOpen = false

    var isMoreMenuVisible: Bool { moreMenuOpen }

    override var isFlipped: Bool { true }

    func configure(primary: [ActionCatalog.MenuItem],
                   extended: [ActionCatalog.MenuItem],
                   available: Set<String>) {
        subviews.forEach { $0.removeFromSuperview() }
        moreMenu = nil
        moreMenuOpen = false

        let buttonSize = CGSize(width: 68, height: 30)
        let gap: CGFloat = 6
        let origin = CGPoint(x: 10, y: 10)
        for (index, item) in primary.enumerated() {
            let button = RingButton(title: item.label, intent: item.intent)
            button.frame = gridFrame(index, size: buttonSize, gap: gap, origin: origin)
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 13, weight: .semibold)
            button.contentTintColor = .labelColor
            button.toolTip = item.label
            button.setAccessibilityLabel(item.label)
            button.target = self
            button.action = #selector(actionButtonPressed(_:))
            button.isEnabled = ActionCatalog.resolve(item.intent, available: available) != nil
            addSubview(button)
        }

        let chat = RingButton(title: "聊天")
        chat.frame = gridFrame(primary.count, size: buttonSize, gap: gap, origin: origin)
        chat.bezelStyle = .rounded
        chat.font = .systemFont(ofSize: 13, weight: .semibold)
        chat.contentTintColor = .labelColor
        chat.setAccessibilityLabel("聊天")
        chat.target = self
        chat.action = #selector(chatButtonPressed)
        addSubview(chat)

        if !extended.isEmpty {
            let more = RingButton(title: "更多")
            more.frame = gridFrame(primary.count + 1, size: buttonSize, gap: gap, origin: origin)
            more.bezelStyle = .rounded
            more.font = .systemFont(ofSize: 13, weight: .semibold)
            more.setAccessibilityLabel("更多")
            more.target = self
            more.action = #selector(moreButtonPressed(_:))
            addSubview(more)
        }

        let menu = NSMenu(title: "更多")
        for item in extended {
            let menuItem = NSMenuItem(
                title: item.label,
                action: #selector(extendedItemPressed(_:)),
                keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item.intent.rawValue
            menuItem.toolTip = item.label
            menuItem.isEnabled = ActionCatalog.resolve(item.intent, available: available) != nil
            menu.addItem(menuItem)
        }
        if menu.items.isEmpty {
            let empty = NSMenuItem(title: "暂无扩展动作", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        moreMenu = menu
    }

    func dismissMoreMenu() {
        moreMenu?.cancelTracking()
        moreMenuOpen = false
    }

    private func gridFrame(_ index: Int, size: CGSize, gap: CGFloat, origin: CGPoint) -> CGRect {
        CGRect(
            x: origin.x + CGFloat(index % 4) * (size.width + gap),
            y: origin.y + CGFloat(index / 4) * (size.height + gap),
            width: size.width,
            height: size.height)
    }

    @objc private func actionButtonPressed(_ sender: RingButton) {
        guard let intent = sender.intent, sender.isEnabled else { return }
        onAction?(intent)
    }

    @objc private func chatButtonPressed() {
        onChat?()
    }

    @objc private func moreButtonPressed(_ sender: NSButton) {
        guard let moreMenu else { return }
        moreMenuOpen = true
        moreMenu.popUp(
            positioning: nil,
            at: CGPoint(x: sender.frame.minX, y: sender.frame.maxY + 4),
            in: self)
        moreMenuOpen = false
    }

    @objc private func extendedItemPressed(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let intent = ActionIntent(rawValue: raw),
              sender.isEnabled else { return }
        onAction?(intent)
    }
}
