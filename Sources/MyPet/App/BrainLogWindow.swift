import AppKit

/// 「查看日志」窗口：按 Trace 展示一条完整的业务脑路，而不是把 JSONL 当文本编辑器打开。
final class BrainLogWindowController: NSWindowController, NSWindowDelegate,
                                      NSTableViewDataSource, NSTableViewDelegate,
                                      NSSearchFieldDelegate {

    private var snapshot = BrainLogAnalyzer.load()
    private var visibleTraces: [BrainLogTrace] = []
    private var selectedTraceID: String?

    private let traceTable = NSTableView()
    private let detailView = NSTextView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let resultLabel = NSTextField(labelWithString: "")
    private var filterPopup: NSPopUpButton!
    private var searchField: NSSearchField!
    private var refreshTimer: Timer?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Living Desktop 脑路与日志"
        window.minSize = NSSize(width: 860, height: 560)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if refreshTimer == nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.refresh()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: Layout

    private func buildContent() -> NSView {
        searchField = NSSearchField()
        searchField.placeholderString = "搜索目标、场景、理由、动作…"
        searchField.delegate = self
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        filterPopup = NSPopUpButton()
        filterPopup.addItems(withTitles: BrainLogFilter.allCases.map(\.rawValue))
        filterPopup.target = self
        filterPopup.action = #selector(filterChanged)

        let refreshButton = NSButton(title: "刷新", target: self, action: #selector(refresh))
        refreshButton.bezelStyle = .rounded
        let openFolder = NSButton(title: "打开数据目录", target: self, action: #selector(openDataFolder))
        openFolder.bezelStyle = .rounded

        let toolbar = NSStackView(views: [
            NSTextField(labelWithString: "日志视图"), filterPopup, searchField,
            refreshButton, openFolder,
        ])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 10

        summaryLabel.font = NSFont.systemFont(ofSize: 12)
        summaryLabel.textColor = .secondaryLabelColor
        resultLabel.font = NSFont.systemFont(ofSize: 11)
        resultLabel.textColor = .secondaryLabelColor

        let summaryStack = NSStackView(views: [summaryLabel, resultLabel])
        summaryStack.orientation = .horizontal
        summaryStack.spacing = 12

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("trace"))
        column.title = "关联脑路"
        traceTable.addTableColumn(column)
        traceTable.headerView = nil
        traceTable.delegate = self
        traceTable.dataSource = self
        traceTable.rowHeight = 68
        traceTable.usesAlternatingRowBackgroundColors = true
        traceTable.selectionHighlightStyle = .regular
        traceTable.allowsEmptySelection = false
        traceTable.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        let listScroll = NSScrollView()
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.borderType = .bezelBorder
        listScroll.documentView = traceTable
        listScroll.widthAnchor.constraint(equalToConstant: 360).isActive = true

        detailView.isEditable = false
        detailView.isSelectable = true
        detailView.usesFindBar = true
        detailView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        detailView.textColor = .labelColor
        detailView.backgroundColor = .textBackgroundColor
        detailView.textContainerInset = NSSize(width: 16, height: 16)
        // NSTextView 作为 NSScrollView 的 documentView 时没有可靠的内在尺寸；
        // 明确让它随右栏宽度伸缩、按内容垂直滚动，否则 string 已写入但文档区域
        // 可能保持为零尺寸，表现为右侧完全空白。
        detailView.isVerticallyResizable = true
        detailView.isHorizontallyResizable = false
        detailView.autoresizingMask = [.width]
        detailView.minSize = NSSize(width: 0, height: 0)
        detailView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                    height: CGFloat.greatestFiniteMagnitude)
        detailView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)
        detailView.textContainer?.widthTracksTextView = true

        let detailScroll = NSScrollView()
        detailScroll.hasVerticalScroller = true
        detailScroll.hasHorizontalScroller = false
        detailScroll.autohidesScrollers = true
        detailScroll.borderType = .bezelBorder
        detailScroll.documentView = detailView
        detailScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 440).isActive = true
        detailScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let body = NSStackView(views: [listScroll, detailScroll])
        body.orientation = .horizontal
        body.spacing = 10

        let root = NSStackView(views: [toolbar, summaryStack, body])
        root.orientation = .vertical
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            body.heightAnchor.constraint(greaterThanOrEqualToConstant: 360),
        ])
        return container
    }

    // MARK: Data

    @objc private func refresh() {
        let previous = selectedTraceID
        snapshot = BrainLogAnalyzer.load()
        let filter = BrainLogFilter.allCases[safe: filterPopup?.indexOfSelectedItem ?? 0] ?? .all
        let query = searchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        visibleTraces = snapshot.traces.filter { trace in
            guard filter.matches(trace) else { return false }
            guard !query.isEmpty else { return true }
            return searchableText(trace).localizedCaseInsensitiveContains(query)
        }
        updateSummary(filter: filter, query: query)
        traceTable.reloadData()

        if let previous, let row = visibleTraces.firstIndex(where: { $0.id == previous }) {
            selectTrace(at: row)
        } else if !visibleTraces.isEmpty {
            selectTrace(at: 0)
        } else {
            traceTable.deselectAll(nil)
            selectedTraceID = nil
            detailView.string = emptyDetailText()
        }
    }

    private func updateSummary(filter: BrainLogFilter, query: String) {
        let s = snapshot.summary
        summaryLabel.stringValue = "脑路 \(s.chainCount) · 已完成 \(s.completedCount) · 已中断 \(s.interruptedCount) · " +
            "未收束 \(s.openCount) · 兜底 \(s.fallbackCount) · 平均模型耗时 \(s.averageLatencyMs) ms"
        let suffix = query.isEmpty ? "" : " · 搜索：\(query)"
        resultLabel.stringValue = "\(filter.rawValue)显示 \(visibleTraces.count) 条，\(s.itemCount) 条原始事件\(suffix)"
    }

    private func searchableText(_ trace: BrainLogTrace) -> String {
        ([trace.title, trace.status, trace.actorSummary] +
            trace.analysis + trace.items.flatMap { [$0.title, $0.summary, $0.raw] }).joined(separator: "\n")
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleTraces.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let trace = visibleTraces[row]
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: trace.title)
        title.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let subtitle = NSTextField(labelWithString: "\(Self.dateFormatter.string(from: trace.date)) · \(trace.status)")
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = trace.status == "已中断" ? .systemOrange : .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        let actors = NSTextField(labelWithString: trace.actorSummary)
        actors.font = NSFont.systemFont(ofSize: 10)
        actors.textColor = .tertiaryLabelColor
        actors.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [title, subtitle, actors])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = traceTable.selectedRow
        selectTrace(at: row)
    }

    /// 程序化选中和用户点击都经过同一条路径。
    /// NSTableView 首次 reload 后的 selectRowIndexes 不一定发送选择通知，
    /// 不能把右侧详情更新依赖在通知上。
    private func selectTrace(at row: Int) {
        guard visibleTraces.indices.contains(row) else { return }
        if traceTable.selectedRow != row {
            traceTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let trace = visibleTraces[row]
        selectedTraceID = trace.id
        detailView.string = detailText(for: trace)
    }

    // MARK: Detail

    private func detailText(for trace: BrainLogTrace) -> String {
        var lines = [
            "脑路：\(trace.title)",
            "状态：\(trace.status)",
            "开始：\(Self.dateFormatter.string(from: trace.date))",
            "关联 Trace：\(trace.id)",
            "参与模块：\(trace.actorSummary)",
            "",
            "【业务结论】",
        ]
        lines += trace.analysis.enumerated().map { "\($0.offset + 1). \($0.element)" }
        lines += ["", "【链路耗时】"]
        lines += latencySummary(for: trace)
        lines += ["", "【关联链路】"]

        for (index, item) in trace.items.enumerated() {
            lines += [
                "",
                "[\(index + 1)] \(Self.dateFormatter.string(from: item.date)) · \(item.title)",
                "摘要：\(item.summary)",
                "类型：\(item.kind.rawValue) · 模块：\(BrainLogAnalyzer.brainLabel(item.actor))",
                "业务分析：",
            ]
            lines += item.analysis.map { "  • \($0)" }
            lines.append("详细信息：")
            for detail in item.details {
                lines.append("  \(detail.label)：\(detail.value)")
            }
            lines += ["原始记录：", item.raw]
        }
        return lines.joined(separator: "\n")
    }

    private func latencySummary(for trace: BrainLogTrace) -> [String] {
        let timedItems = trace.items.compactMap { item -> (String, Int)? in
            guard let latency = item.latencyMs else { return nil }
            return (item.actor, latency)
        }
        guard !timedItems.isEmpty else {
            return ["没有记录可计时的模型/行动请求。"]
        }

        let total = timedItems.reduce(0) { $0 + $1.1 }
        let average = total / timedItems.count
        let longest = timedItems.map { $0.1 }.max() ?? 0
        var lines = [
            "可计时事件：\(timedItems.count) 条",
            "请求/执行累计耗时：\(total) ms",
            "请求/执行平均耗时：\(average) ms",
            "最长单次耗时：\(longest) ms",
        ]
        let byActor = Dictionary(grouping: timedItems, by: { $0.0 })
            .map { actor, values in
                let sum = values.reduce(0) { $0 + $1.1 }
                return (actor, values.count, sum, sum / values.count)
            }
            .sorted { $0.0 < $1.0 }
        lines += byActor.map { actor, count, sum, average in
            "\(BrainLogAnalyzer.brainLabel(actor))：\(count) 次 · 累计 \(sum) ms · 平均 \(average) ms"
        }
        if let stay = trace.items.first(where: { $0.kind == .outcome })?.details.first(where: {
            $0.label == "停留时间"
        })?.value {
            lines.append("场景停留：\(stay)")
        }
        return lines
    }

    private func emptyDetailText() -> String {
        if snapshot.traces.isEmpty {
            return "还没有可显示的脑路。\n\n日志会在目标规划、行动脑决策、场景结局或记忆产生后出现在这里。"
        }
        return "当前筛选没有匹配的脑路。"
    }

    // MARK: Actions

    @objc private func filterChanged() { refresh() }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    @objc private func openDataFolder() {
        NSWorkspace.shared.open(snapshot.dataDirectory)
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
