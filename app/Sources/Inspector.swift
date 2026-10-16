// Bottom inspector: cross-references, data inspector, patches.
import AppKit

final class SimpleTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    let scroll = NSScrollView()
    var rows: [[String]] = []
    var onActivate: ((Int) -> Void)?
    init(columns: [(String, CGFloat)]) {
        super.init()
        for (i, c) in columns.enumerated() {
            let col = NSTableColumn(identifier: .init("c\(i)")); col.title = c.0; col.width = c.1
            col.minWidth = 40; table.addTableColumn(col)
        }
        table.rowHeight = 19; table.dataSource = self; table.delegate = self
        table.usesAlternatingRowBackgroundColors = true; table.style = .plain
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.target = self; table.doubleAction = #selector(activated)
        scroll.documentView = table; scroll.hasVerticalScroller = true
    }
    @objc private func activated() { if table.clickedRow >= 0 { onActivate?(table.clickedRow) } }
    func set(_ r: [[String]]) { rows = r; table.reloadData() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let idx = Int(c?.identifier.rawValue.dropFirst() ?? "0") ?? 0
        let id = NSUserInterfaceItemIdentifier("t")
        let f = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let t = NSTextField(labelWithString: ""); t.identifier = id
            t.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular); t.lineBreakMode = .byTruncatingTail; return t
        }()
        f.stringValue = idx < rows[row].count ? rows[row][idx] : ""
        f.textColor = idx == 0 ? .secondaryLabelColor : .labelColor
        return f
    }
}

enum DataInspector {
    /// Interprets up to 16 little-endian bytes at an address.
    static func describe(addr: String, hex: String) -> String {
        let b = HexRenderer.bytes(hex)
        guard !b.isEmpty else { return "No data at \(addr)" }
        func u(_ n: Int) -> UInt64? { b.count >= n ? (0..<n).reduce(0) { $0 | (UInt64(b[$1]) << UInt64(8 * $1)) } : nil }
        var out = "Address  \(addr)\nBytes    " + b.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ") + "\n\n"
        func line(_ k: String, _ v: String) { out += k.padding(toLength: 9, withPad: " ", startingAt: 0) + v + "\n" }
        if let v = u(1) { line("uint8", "\(v)  (0x\(String(v, radix: 16)))"); line("int8", "\(Int8(truncatingIfNeeded: v))") }
        if let v = u(2) { line("uint16", "\(v)  (0x\(String(v, radix: 16)))"); line("int16", "\(Int16(truncatingIfNeeded: v))") }
        if let v = u(4) { line("uint32", "\(v)  (0x\(String(v, radix: 16)))"); line("int32", "\(Int32(truncatingIfNeeded: v))"); line("float32", "\(Float(bitPattern: UInt32(v)))") }
        if let v = u(8) { line("uint64", "\(v)  (0x\(String(v, radix: 16)))"); line("int64", "\(Int64(bitPattern: v))"); line("float64", "\(Double(bitPattern: v))") }
        let s = b.prefix(while: { $0 >= 32 && $0 < 127 })
        if s.count >= 2 { line("string", "\"" + String(decoding: s, as: UTF8.self) + "\"") }
        return out
    }
}

final class InspectorViewController: NSViewController {
    let xrefs = SimpleTable(columns: [("Address", 150), ("Symbol", 360), ("Type", 90)])
    let patches = SimpleTable(columns: [("Address", 150), ("Original", 170), ("Patched", 170), ("Symbol", 200)])
    let data = NSTextView()
    let tabs = NSTabView()
    var onGoto: ((String) -> Void)?
    private var xrefAddrs: [String] = [], patchAddrs: [String] = []

    override func loadView() {
        tabs.tabViewType = .topTabsBezelBorder; tabs.controlSize = .small
        let x = NSTabViewItem(identifier: "xrefs"); x.label = "Cross-references"; x.view = xrefs.scroll
        let d = NSTabViewItem(identifier: "data"); d.label = "Data Inspector"
        let dsv = NSScrollView(); dsv.documentView = data; dsv.hasVerticalScroller = true
        data.isEditable = false; data.font = Theme.font; data.textContainerInset = NSSize(width: 8, height: 6)
        d.view = dsv
        let p = NSTabViewItem(identifier: "patches"); p.label = "Patches"; p.view = patches.scroll
        [x, d, p].forEach { tabs.addTabViewItem($0) }
        view = tabs
        xrefs.onActivate = { [weak self] i in if let s = self, i < s.xrefAddrs.count { s.onGoto?(s.xrefAddrs[i]) } }
        patches.onActivate = { [weak self] i in if let s = self, i < s.patchAddrs.count { s.onGoto?(s.patchAddrs[i]) } }
    }

    func showXrefs(_ r: XrefResult) {
        xrefAddrs = r.items.map(\.a)
        xrefs.set(r.items.map { [$0.a, $0.n, $0.t] })
        tabs.tabViewItem(at: 0).label = "Cross-references (\(r.items.count))"
    }
    func showData(addr: String, hex: String) { data.string = DataInspector.describe(addr: addr, hex: hex) }
    func showPatches(_ l: PatchList) {
        patchAddrs = l.items.map(\.a)
        patches.set(l.items.map { [$0.a, $0.orig, $0.new, $0.n] })
        tabs.tabViewItem(at: 2).label = "Patches (\(l.items.count))"
    }
    func select(_ id: String) { tabs.selectTabViewItem(withIdentifier: id) }
}
