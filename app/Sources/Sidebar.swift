// Left sidebar: Procedures / Names / Strings / Imports / Exports with live filtering.
import AppKit

struct SidebarItem { let addr: String; let name: String; let info: String }

final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    enum Kind: Int, CaseIterable {
        case procs, names, strings, imports, exports
        var title: String { ["Procs", "Names", "Strings", "Imports", "Exports"][rawValue] }
        var api: String { ["funcs", "names", "strings", "imports", "exports"][rawValue] }
    }
    var fetch: ((Kind, String) async -> [SidebarItem])?
    var onSelect: ((String) -> Void)?
    private(set) var kind: Kind = .procs
    private(set) var items: [SidebarItem] = []
    private let segmented = NSSegmentedControl(labels: Kind.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    let search = NSSearchField()
    private let table = NSTableView()
    private let count = NSTextField(labelWithString: "")
    private var task: Task<Void, Never>?
    private var quiet = false

    override func loadView() {
        let root = NSVisualEffectView(); root.material = .sidebar; root.blendingMode = .behindWindow
        view = root
        segmented.target = self; segmented.action = #selector(kindChanged); segmented.selectedSegment = 0
        segmented.controlSize = .small; segmented.segmentStyle = .texturedRounded
        search.placeholderString = "Filter"; search.delegate = self; search.controlSize = .regular
        let col = NSTableColumn(identifier: .init("main")); col.resizingMask = .autoresizingMask
        table.addTableColumn(col); table.headerView = nil; table.rowHeight = 20
        table.dataSource = self; table.delegate = self
        table.backgroundColor = .clear; table.style = .sourceList
        table.target = self; table.action = #selector(rowClicked)
        let sv = NSScrollView(); sv.documentView = table; sv.hasVerticalScroller = true; sv.drawsBackground = false
        count.font = .systemFont(ofSize: 11); count.textColor = .secondaryLabelColor
        for v in [segmented, search, sv, count] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            segmented.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            segmented.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            search.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 8),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            sv.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
            sv.leadingAnchor.constraint(equalTo: root.leadingAnchor), sv.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sv.bottomAnchor.constraint(equalTo: count.topAnchor, constant: -4),
            count.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            count.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
    }

    @objc private func kindChanged() { kind = Kind(rawValue: segmented.selectedSegment) ?? .procs; reload() }
    @objc private func rowClicked() { let r = table.clickedRow; if r >= 0 && r < items.count { onSelect?(items[r].addr) } }
    func controlTextDidChange(_ obj: Notification) { reload() }
    func tableViewSelectionDidChange(_ n: Notification) {
        let r = table.selectedRow
        if !quiet && r >= 0 && r < items.count { onSelect?(items[r].addr) }
    }

    func reload() {
        task?.cancel()
        let k = kind, q = search.stringValue
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self = self, let fetch = self.fetch else { return }
            let result = await fetch(k, q)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.items = result
                self.table.reloadData()
                self.count.stringValue = "\(result.count) item\(result.count == 1 ? "" : "s")"
            }
        }
    }

    /// Selects the row for `addr` without triggering navigation.
    func highlight(_ addr: String) {
        guard let i = items.firstIndex(where: { $0.addr == addr }) else { return }
        quiet = true
        table.selectRowIndexes([i], byExtendingSelection: false)
        table.scrollRowToVisible(i)
        quiet = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? SidebarCell) ?? SidebarCell(identifier: id)
        cell.set(items[row])
        return cell
    }
}

final class SidebarCell: NSTableCellView {
    private let name = NSTextField(labelWithString: "")
    private let info = NSTextField(labelWithString: "")
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero); self.identifier = identifier
        name.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular); name.lineBreakMode = .byTruncatingMiddle
        info.font = .systemFont(ofSize: 10.5); info.textColor = .secondaryLabelColor
        info.setContentCompressionResistancePriority(.required, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [name, info] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), name.centerYAnchor.constraint(equalTo: centerYAnchor),
            info.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), info.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: info.leadingAnchor, constant: -6),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    func set(_ i: SidebarItem) { name.stringValue = i.name; info.stringValue = i.info }
}
