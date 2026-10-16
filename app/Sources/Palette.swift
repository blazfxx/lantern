// Command palette (⇧⌘P / ⌘K): fuzzy-jump to procedures and names, or run a command.
import AppKit

struct PaletteEntry {
    let title: String
    let detail: String
    let run: () -> Void
}

final class PalettePanel: NSPanel, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var commands: [PaletteEntry] = []
    var search: ((String) async -> [PaletteEntry])?
    private let field = NSSearchField()
    private let table = NSTableView()
    private var rows: [PaletteEntry] = []
    private var task: Task<Void, Never>?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden; titlebarAppearsTransparent = true
        isMovableByWindowBackground = true; hidesOnDeactivate = true; level = .floating
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        let bg = NSVisualEffectView(); bg.material = .hudWindow; bg.state = .active
        contentView = bg
        field.placeholderString = "Jump to a procedure or name, or type a command…"
        field.delegate = self; field.font = .systemFont(ofSize: 15)
        let col = NSTableColumn(identifier: .init("c")); col.resizingMask = .autoresizingMask
        table.addTableColumn(col); table.headerView = nil; table.rowHeight = 26
        table.dataSource = self; table.delegate = self; table.backgroundColor = .clear
        table.target = self; table.doubleAction = #selector(runSelected)
        let sv = NSScrollView(); sv.documentView = table; sv.drawsBackground = false; sv.hasVerticalScroller = true
        for v in [field, sv] { v.translatesAutoresizingMaskIntoConstraints = false; bg.addSubview(v) }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: bg.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -14),
            sv.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            sv.leadingAnchor.constraint(equalTo: bg.leadingAnchor), sv.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            sv.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])
    }
    override var canBecomeKey: Bool { true }

    func present(over window: NSWindow) {
        field.stringValue = ""
        refresh()
        let f = window.frame
        setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.maxY - 140 - frame.height / 2))
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
    }

    private func refresh() {
        task?.cancel()
        let q = field.stringValue
        let cmds = commands.filter { q.isEmpty || $0.title.lowercased().contains(q.lowercased()) }
        rows = cmds; table.reloadData(); if !rows.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        guard !q.isEmpty, let search = search else { return }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            let found = await search(q)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self = self else { return }
                self.rows = found + cmds
                self.table.reloadData()
                if !self.rows.isEmpty { self.table.selectRowIndexes([0], byExtendingSelection: false) }
            }
        }
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(insertNewline(_:)): runSelected(); return true
        case #selector(cancelOperation(_:)): orderOut(nil); return true
        case #selector(moveDown(_:)): move(1); return true
        case #selector(moveUp(_:)): move(-1); return true
        default: return false
        }
    }
    private func move(_ d: Int) {
        guard !rows.isEmpty else { return }
        let i = max(0, min(rows.count - 1, table.selectedRow + d))
        table.selectRowIndexes([i], byExtendingSelection: false); table.scrollRowToVisible(i)
    }
    @objc private func runSelected() {
        let i = table.selectedRow
        guard i >= 0 && i < rows.count else { return }
        let e = rows[i]
        orderOut(nil)
        e.run()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let t = NSTextField(labelWithString: rows[row].title); t.font = .systemFont(ofSize: 13)
        let d = NSTextField(labelWithString: rows[row].detail); d.font = .systemFont(ofSize: 11); d.textColor = .secondaryLabelColor
        for v in [t, d] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
        NSLayoutConstraint.activate([
            t.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 14), t.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            d.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -14), d.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            t.trailingAnchor.constraint(lessThanOrEqualTo: d.leadingAnchor, constant: -8),
        ])
        return cell
    }
}
