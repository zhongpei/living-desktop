import AppKit
import ImageIO
import MyPetContent
import UniformTypeIdentifiers

/// The registry is the only catalog. This window keeps no package state of its own.
@MainActor
final class ContentManagerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    var records: () -> [ContentRegistry.Record] = { [] }
    var diagnostics: () -> [String] = { [] }
    var onImport: (([URL], Bool) throws -> ContentRegistry.ImportResult)?
    var onSetEnabled: ((Bool, ContentPackageKind, String) throws -> Void)?
    var onRemove: ((ContentRegistry.Record) throws -> Void)?

    private var rows: [ContentRegistry.Record] = []
    private var previews: [URL: NSImage] = [:]
    private var missingPreviews = Set<URL>()
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
        previews.removeAll()
        missingPreviews.removeAll()
        table.reloadData()
        updateControls()
    }

    private func buildContent() {
        for (id, title, width) in [
            ("kind", "类型", 65.0), ("name", "形象 / 名称 / ID", 310.0),
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
        table.rowHeight = 56
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
        let label = NSTextField(labelWithString: value)
        guard id == "name" else { return label }
        label.lineBreakMode = .byTruncatingMiddle
        let image = NSImageView()
        image.image = preview(for: record)
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            image.widthAnchor.constraint(equalToConstant: 48),
            image.heightAnchor.constraint(equalToConstant: 48),
        ])
        let cell = NSStackView(views: [image, label])
        cell.orientation = .horizontal
        cell.alignment = .centerY
        cell.spacing = 8
        return cell
    }

    private func preview(for record: ContentRegistry.Record) -> NSImage? {
        if let cached = previews[record.url] { return cached }
        guard !missingPreviews.contains(record.url), let manifest = record.manifest,
              let data = try? ContentPackageReader.previewFrameData(
                at: record.url, manifest: manifest),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let frame = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 96,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else {
            missingPreviews.insert(record.url)
            return nil
        }
        let thumbnail = NSImage(cgImage: frame, size: NSSize(width: 48, height: 48))
        previews[record.url] = thumbnail
        return thumbnail
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
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty, let onImport else { return }
        let urls = panel.urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard confirm("导入 \(urls.count) 个内容包？同 ID 的较高修订也会更新。") else { return }
        do {
            let result = try onImport(urls, true)
            reload()
            let alert = NSAlert()
            alert.alertStyle = result.failures.isEmpty ? .informational : .warning
            alert.messageText = "已导入 \(result.imported.count) 个内容包"
            if !result.failures.isEmpty {
                let details = result.failures.prefix(12).map {
                    "\($0.url.lastPathComponent)：\($0.error)"
                }.joined(separator: "\n")
                alert.informativeText = "\(result.failures.count) 个未导入：\n\(details)" +
                    (result.failures.count > 12 ? "\n其余 \(result.failures.count - 12) 个失败。" : "")
            }
            alert.runModal()
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
