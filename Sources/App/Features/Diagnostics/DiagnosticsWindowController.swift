import AppKit
import Diagnostics
import UniformTypeIdentifiers

@MainActor
final class DiagnosticsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let diagnostics: DiagnosticTimeline
    private let allowsPrivateExport: Bool
    private var events: [DiagnosticEvent] = []
    private let tableView = NSTableView()
    private let detailField = NSTextField(wrappingLabelWithString: "")
    private let includePrivateButton = NSButton(
        checkboxWithTitle: NSLocalizedString("Include host names and network addresses", comment: "include private diagnostics"),
        target: nil,
        action: nil
    )

    init(diagnostics: DiagnosticTimeline, allowsPrivateExport: Bool = true) {
        self.diagnostics = diagnostics
        self.allowsPrivateExport = allowsPrivateExport
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("Diagnostics", comment: "diagnostics title")
        window.minSize = NSSize(width: 640, height: 400)
        super.init(window: window)
        buildInterface()
        if !allowsPrivateExport {
            includePrivateButton.state = .off
            includePrivateButton.isEnabled = false
            includePrivateButton.toolTip = NSLocalizedString("Managed by your organization", comment: "managed setting tooltip")
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        Task { await reload() }
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        for (id, title, width) in [
            ("time", NSLocalizedString("Time", comment: "time"), 145.0),
            ("level", NSLocalizedString("Level", comment: "level"), 75.0),
            ("category", NSLocalizedString("Category", comment: "category"), 95.0),
            ("event", NSLocalizedString("Event", comment: "diagnostic event"), 420.0)
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        detailField.textColor = .secondaryLabelColor
        detailField.maximumNumberOfLines = 3
        detailField.lineBreakMode = .byTruncatingMiddle
        detailField.translatesAutoresizingMaskIntoConstraints = false

        let refresh = NSButton(title: NSLocalizedString("Refresh", comment: "refresh"), target: self, action: #selector(refresh))
        let clear = NSButton(title: NSLocalizedString("Clear", comment: "clear"), target: self, action: #selector(clear))
        let export = NSButton(title: NSLocalizedString("Export…", comment: "export diagnostics"), target: self, action: #selector(exportDiagnostics))
        let buttons = NSStackView(views: [includePrivateButton, NSView(), refresh, clear, export])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scroll)
        content.addSubview(detailField)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: detailField.topAnchor, constant: -8),
            detailField.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            detailField.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            detailField.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { events.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard events.indices.contains(row), let tableColumn else { return nil }
        let event = events[row]
        let id = tableColumn.identifier
        let field = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? NSTextField(labelWithString: "")
        field.identifier = id
        field.lineBreakMode = .byTruncatingTail
        switch id.rawValue {
        case "time": field.stringValue = Self.dateFormatter.string(from: event.timestamp)
        case "level": field.stringValue = event.level.rawValue.uppercased()
        case "category": field.stringValue = event.category.rawValue
        default: field.stringValue = "\(event.code): \(event.message)"
        }
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard events.indices.contains(row) else { detailField.stringValue = ""; return }
        let event = events[row]
        let fields = event.fields.keys.sorted().joined(separator: ", ")
        detailField.stringValue = fields.isEmpty ? event.message : "\(event.message)\nFields: \(fields)"
    }

    @objc private func refresh() { Task { await reload() } }

    @objc private func clear() {
        Task {
            await diagnostics.removeAll()
            await reload()
        }
    }

    @objc private func exportDiagnostics() {
        let includePrivate = allowsPrivateExport && includePrivateButton.state == .on
        Task {
            do {
                let data = try await diagnostics.export(includePrivateNetworkData: includePrivate)
                guard let window else { return }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.json]
                panel.nameFieldStringValue = "RemoteDesktop-Diagnostics.json"
                panel.beginSheetModal(for: window) { response in
                    guard response == .OK, let url = panel.url else { return }
                    do { try data.write(to: url, options: .atomic) }
                    catch { NSAlert(error: error).beginSheetModal(for: window) }
                }
            } catch { if let window { _ = await NSAlert(error: error).beginSheetModal(for: window) } }
        }
    }

    private func reload() async {
        let snapshot = await diagnostics.snapshot()
        events = snapshot.sorted { $0.timestamp > $1.timestamp }
        tableView.reloadData()
        detailField.stringValue = String(format: NSLocalizedString("%d diagnostic events. Private network values are redacted by default.", comment: "diagnostic count"), events.count)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()
}
