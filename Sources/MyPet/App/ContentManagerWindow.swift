import AppKit
import MyPetContent
import UniformTypeIdentifiers

/// The registry is the only catalog. This window keeps no package state of its own.
@MainActor
final class ContentManagerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    var records: () -> [ContentRegistry.Record] = { [] }
    var diagnostics: () -> [String] = { [] }
    var onImport: ((URL, Bool) throws -> Void)?
    var onSetEnabled: ((Bool, ContentPackageKind, String) throws -> Void)?
    var onRemove: ((ContentRegistry.Record) throws -> Void)?

    private var rows: [ContentRegistry.Record] = []
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let toggle = NSButton(title: "停用", target: nil, action: nil)
    private let remove = NSButton(title: "移除", target: nil, action: nil)

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "内容包管理"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func reload() {
        rows = records()
        table.reloadData()
        updateControls()
    }

    private func buildContent() {
        for (id, title, width) in [
            ("kind", "类型", 65.0), ("name", "名称 / ID", 230.0),
            ("revision", "修订", 55.0), ("source", "来源", 70.0),
            ("state", "状态", 90.0),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.target = self
        table.action = #selector(selectionChanged)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let importButton = NSButton(title: "导入 .mypetpack…", target: self, action: #selector(importPack))
        toggle.target = self
        toggle.action = #selector(togglePack)
        remove.target = self
        remove.action = #selector(removePack)
        let buttons = NSStackView(views: [importButton, toggle, remove])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        status.maximumNumberOfLines = 3
        status.lineBreakMode = .byWordWrapping
        status.textColor = .secondaryLabelColor
        let root = NSStackView(views: [scroll, status, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 250),
            status.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        window?.contentView = container
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let id = tableColumn?.identifier.rawValue else { return nil }
        let record = rows[row]
        let value: String
        switch id {
        case "kind": value = record.manifest?.kind.rawValue ?? "?"
        case "name": value = record.manifest.map { "\($0.name) (\($0.id))" } ?? record.url.lastPathComponent
        case "revision": value = record.manifest.map { String($0.revision) } ?? "—"
        case "source": value = record.source == .builtIn ? "内置" : "用户"
        case "state":
            switch record.status {
            case .enabled: value = diagnostic(for: record) == nil ? "已启用" : "不可用"
            case .disabled: value = "已停用"
            case .corrupt: value = "损坏"
            }
        default: value = ""
        }
        return NSTextField(labelWithString: value)
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }

    @objc private func selectionChanged() { updateControls() }

    private var selected: ContentRegistry.Record? {
        rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
    }

    private func diagnostic(for record: ContentRegistry.Record) -> String? {
        guard let manifest = record.manifest else { return nil }
        let prefix = "\(manifest.kind.rawValue)/\(manifest.id):"
        return diagnostics().first { $0.hasPrefix(prefix) }
    }

    private func updateControls() {
        guard let selected else {
            toggle.isEnabled = false
            remove.isEnabled = false
            status.stringValue = rows.isEmpty ? "尚无内容包。导入包后即可在这里管理。" : "请选择一个内容包。"
            return
        }
        toggle.title = selected.status == .disabled ? "启用" : "停用"
        toggle.isEnabled = selected.status != .corrupt && selected.manifest != nil
        remove.isEnabled = selected.source == .user
        status.stringValue = selected.reason ?? diagnostic(for: selected) ??
            "启停或移除活动包会先安全结束当前角色/角色组会话，再重新启动。内置包只能停用。"
    }

    private func confirm(_ message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "当前会话会在事件边界结束并重新启动；内置包不会被删除。"
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func report(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "内容包操作失败"
        alert.informativeText = String(describing: error)
        alert.runModal()
        reload()
    }

    @objc private func importPack() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mypetpack") ?? .data]
        panel.allowsOtherFileTypes = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let onImport else { return }
        do {
            try onImport(url, false)
            reload()
        } catch ContentRegistry.RegistryError.updateNeedsConfirmation {
            guard confirm("更新同 ID 内容包？") else { return }
            do { try onImport(url, true); reload() } catch { report(error) }
        } catch { report(error) }
    }

    @objc private func togglePack() {
        guard let record = selected, let manifest = record.manifest, let onSetEnabled else { return }
        let enabled = record.status == .disabled
        guard confirm("\(enabled ? "启用" : "停用") \(manifest.name)？") else { return }
        do { try onSetEnabled(enabled, manifest.kind, manifest.id); reload() }
        catch { report(error) }
    }

    @objc private func removePack() {
        guard let record = selected, record.source == .user,
              let onRemove else { return }
        let name = record.manifest?.name ?? record.url.lastPathComponent
        guard confirm("移除 \(name) 的用户安装版本？") else { return }
        do { try onRemove(record); reload() }
        catch { report(error) }
    }
}
