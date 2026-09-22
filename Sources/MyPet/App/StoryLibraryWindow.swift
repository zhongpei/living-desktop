import AppKit
import MyPetCore

/// Read-only view of the same validated, enabled story packs used by CastRuntime.
@MainActor
final class StoryLibraryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private struct Row {
        let groupName: String
        let storyID: String
        let episode: StoryEpisode
        let memberNames: [String: String]
    }

    private let rows: [Row]
    private let table = NSTableView()
    private let detail = NSTextView()

    init(stories: [StoryPack], groups: [CastPack]) {
        let groupsByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.groupID, $0) })
        rows = stories.flatMap { story in
            let group = groupsByID[story.groupID]
            let names = Dictionary(uniqueKeysWithValues: (group?.members ?? []).map { ($0.id, $0.displayName) })
            return story.episodes.map {
                Row(groupName: group?.displayName ?? story.groupID,
                    storyID: story.id, episode: $0, memberNames: names)
            }
        }.sorted {
            ($0.groupName, $0.storyID, $0.episode.title, $0.episode.id) <
                ($1.groupName, $1.storyID, $1.episode.title, $1.episode.id)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Living Desktop 剧情内容"
        window.minSize = NSSize(width: 700, height: 460)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildContent() {
        for (id, title, width) in [("group", "角色组", 110.0), ("episode", "剧集", 190.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        let list = NSScrollView()
        list.documentView = table
        list.hasVerticalScroller = true
        list.widthAnchor.constraint(equalToConstant: 315).isActive = true

        detail.isEditable = false
        detail.isSelectable = true
        detail.drawsBackground = false
        detail.textContainerInset = NSSize(width: 14, height: 12)
        detail.font = .systemFont(ofSize: 13)
        detail.isVerticallyResizable = true
        detail.textContainer?.widthTracksTextView = true
        let details = NSScrollView()
        details.documentView = detail
        details.hasVerticalScroller = true

        let columns = NSStackView(views: [list, details])
        columns.orientation = .horizontal
        columns.spacing = 12
        let summary = NSTextField(labelWithString:
            "当前可用：\(Set(rows.map(\.storyID)).count) 个剧情包，\(rows.count) 段剧集。这里只展示已启用且引用有效的内容。")
        summary.textColor = .secondaryLabelColor
        let root = NSStackView(views: [summary, columns])
        root.orientation = .vertical
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            list.heightAnchor.constraint(equalTo: details.heightAnchor),
            details.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        window?.contentView = container
        detail.string = rows.isEmpty
            ? "没有可查看的剧情。请先在内容包管理中导入并启用与角色组兼容的剧情包。"
            : "选择左侧剧集，查看参与角色、前置条件、动作节拍、分支和效果。\n\n这是结构化剧情，不包含逐字台词。"
        if !rows.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            detail.string = Self.description(of: rows[0])
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let id = tableColumn?.identifier.rawValue else { return nil }
        let item = rows[row]
        let field = NSTextField(labelWithString: id == "group" ? item.groupName : item.episode.title)
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard rows.indices.contains(table.selectedRow) else { return }
        detail.string = Self.description(of: rows[table.selectedRow])
    }

    private static func description(of row: Row) -> String {
        let episode = row.episode
        func names(_ ids: [String]) -> String {
            ids.map { row.memberNames[$0] ?? $0 }.joined(separator: "、")
        }
        func prerequisites(_ items: [StoryPrerequisite]) -> String {
            guard !items.isEmpty else { return "无" }
            return items.map {
                if let fact = $0.requiredFact { return "事实：\(fact)" }
                if let key = $0.relationKey {
                    return "关系：\(key) ≥ \($0.minimum.map { String($0) } ?? "0")"
                }
                return "未指定"
            }.joined(separator: "；")
        }
        func beats(_ items: [StoryBeat]) -> [String] {
            items.enumerated().map { index, beat in
                var parts = ["\(index + 1). \(names(beat.actorIDs)) · \(beat.intent)（\(beat.durationTicks) tick）"]
                if let target = beat.targetID { parts.append("目标：\(target)") }
                if let slot = beat.slotID { parts.append("槽位：\(slot)") }
                if let invite = beat.inviteMemberIDs, !invite.isEmpty { parts.append("邀请：\(names(invite))") }
                for effect in beat.effectsOnSuccess {
                    switch effect.kind {
                    case .relationDelta:
                        parts.append("关系效果：\(effect.relationKey ?? "?") \(effect.delta ?? 0)")
                    case .setFact:
                        parts.append("设置事实：\(effect.fact ?? "?")")
                    }
                }
                return parts.joined(separator: " · ")
            }
        }
        var lines = [
            episode.title,
            "角色组：\(row.groupName) · 剧情包：\(row.storyID)",
            "剧集 ID：\(episode.id)",
            "参与角色：\(names(episode.participants))",
            "前置条件：\(prerequisites(episode.prerequisites))",
            "冷却：\(episode.cooldownTicks) tick",
            "",
            "主线节拍",
        ]
        lines += beats(episode.beats)
        for branch in episode.branches {
            lines += ["", "分支：\(branch.id)（优先级 \(branch.priority)）",
                      "条件：\(prerequisites(branch.prerequisites))"]
            lines += beats(branch.beats)
        }
        return lines.joined(separator: "\n")
    }
}
