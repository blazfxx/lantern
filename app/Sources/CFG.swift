// Control-flow graph: layered layout (pure, testable) and the NSView that draws it.
import AppKit

struct CFGNode {
    let index: Int
    let block: Block
    let rows: [(addr: String, text: NSAttributedString, target: String?)]
    var x: CGFloat = 0, y: CGFloat = 0, w: CGFloat = 0, h: CGFloat = 0
    var rank = 0
    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}
struct CFGEdge { let from: Int; let to: Int; let kind: Int; var back = false }
struct CFGLayout { var nodes: [CFGNode]; var edges: [CFGEdge]; var size: CGSize }

enum CFGLayouter {
    static let charW: CGFloat = 7.3, rowH: CGFloat = 15, pad: CGFloat = 8, hGap: CGFloat = 36, vGap: CGFloat = 54

    static func layout(_ f: FuncDetail) -> CFGLayout {
        var nodes: [CFGNode] = f.blocks.enumerated().map { i, b in
            let rows = AssemblyRenderer.nodeLines(b, showLabel: i > 0)
            var n = CFGNode(index: i, block: b, rows: rows)
            let maxChars = rows.map { $0.text.length }.max() ?? 8
            n.w = max(90, CGFloat(maxChars) * charW + pad * 2)
            n.h = CGFloat(max(1, rows.count)) * rowH + pad * 2
            return n
        }
        guard !nodes.isEmpty else { return CFGLayout(nodes: [], edges: [], size: .zero) }
        let byAddr = Dictionary(uniqueKeysWithValues: nodes.map { ($0.block.a, $0.index) })
        var edges = f.edges.compactMap { e -> CFGEdge? in
            guard let s = byAddr[e.s], let d = byAddr[e.d] else { return nil }
            return CFGEdge(from: s, to: d, kind: e.k)
        }
        var out = Array(repeating: [Int](), count: nodes.count), inn = out
        for (i, e) in edges.enumerated() { out[e.from].append(i); inn[e.to].append(i) }

        // back edges via iterative DFS from the entry (then any unvisited roots)
        var state = Array(repeating: 0, count: nodes.count)
        let roots = [0] + nodes.indices.filter { $0 != 0 && inn[$0].isEmpty } + Array(nodes.indices)
        for r in roots where state[r] == 0 {
            var stack: [(Int, Int)] = [(r, 0)]; state[r] = 1
            while let (n, k) = stack.last {
                if k < out[n].count {
                    stack[stack.count - 1].1 += 1
                    let ei = out[n][k]; let d = edges[ei].to
                    if state[d] == 1 { edges[ei].back = true }
                    else if state[d] == 0 { state[d] = 1; stack.append((d, 0)) }
                } else { state[n] = 2; stack.removeLast() }
            }
        }
        // longest-path ranking over the DAG
        var indeg = nodes.indices.map { n in inn[n].filter { !edges[$0].back }.count }
        var queue = nodes.indices.filter { indeg[$0] == 0 }
        var qi = 0
        while qi < queue.count {
            let n = queue[qi]; qi += 1
            for ei in out[n] where !edges[ei].back {
                let d = edges[ei].to
                nodes[d].rank = max(nodes[d].rank, nodes[n].rank + 1)
                indeg[d] -= 1
                if indeg[d] == 0 { queue.append(d) }
            }
        }
        let maxRank = nodes.map(\.rank).max() ?? 0
        var layers = Array(repeating: [Int](), count: maxRank + 1)
        for n in nodes { layers[n.rank].append(n.index) }
        var pos = Array(repeating: 0, count: nodes.count)
        func setPos() { for l in layers { for (k, n) in l.enumerated() { pos[n] = k } } }
        setPos()
        // barycentre ordering
        for _ in 0..<5 {
            for r in stride(from: 1, to: layers.count, by: 1) {
                var bc: [Int: Double] = [:]
                for n in layers[r] {
                    let ps = inn[n].filter { !edges[$0].back && nodes[edges[$0].from].rank < r }.map { Double(pos[edges[$0].from]) }
                    bc[n] = ps.isEmpty ? Double(pos[n]) : ps.reduce(0, +) / Double(ps.count)
                }
                layers[r].sort { bc[$0]! < bc[$1]! }; setPos()
            }
            for r in stride(from: layers.count - 2, through: 0, by: -1) {
                var bc: [Int: Double] = [:]
                for n in layers[r] {
                    let cs = out[n].filter { !edges[$0].back && nodes[edges[$0].to].rank > r }.map { Double(pos[edges[$0].to]) }
                    bc[n] = cs.isEmpty ? Double(pos[n]) : cs.reduce(0, +) / Double(cs.count)
                }
                layers[r].sort { bc[$0]! < bc[$1]! }; setPos()
            }
        }
        // coordinates
        var y: CGFloat = 24
        for l in layers {
            var x: CGFloat = 0
            for n in l { nodes[n].x = x; nodes[n].y = y; x += nodes[n].w + hGap }
            y += (l.map { nodes[$0].h }.max() ?? 0) + vGap
        }
        func rowWidth(_ l: [Int]) -> CGFloat { l.last.map { nodes[$0].x + nodes[$0].w } ?? 0 }
        let widest = layers.map(rowWidth).max() ?? 0
        for l in layers { let off = (widest - rowWidth(l)) / 2; for n in l { nodes[n].x += off } }
        func resolve(_ l: [Int]) -> [Int] {
            let s = l.sorted { nodes[$0].x < nodes[$1].x }
            var right = -CGFloat.greatestFiniteMagnitude
            for n in s { nodes[n].x = max(nodes[n].x, right + hGap); right = nodes[n].x + nodes[n].w }
            return s
        }
        for _ in 0..<4 {
            for r in stride(from: 1, to: layers.count, by: 1) {
                for n in layers[r] {
                    let ps = inn[n].filter { !edges[$0].back && nodes[edges[$0].from].rank < r }.map { nodes[edges[$0].from].x + nodes[edges[$0].from].w / 2 }
                    if !ps.isEmpty { nodes[n].x = ps.reduce(0, +) / CGFloat(ps.count) - nodes[n].w / 2 }
                }
                layers[r] = resolve(layers[r])
            }
            for r in stride(from: layers.count - 2, through: 0, by: -1) {
                for n in layers[r] {
                    let cs = out[n].filter { !edges[$0].back && nodes[edges[$0].to].rank > r }.map { nodes[edges[$0].to].x + nodes[edges[$0].to].w / 2 }
                    if !cs.isEmpty { nodes[n].x = cs.reduce(0, +) / CGFloat(cs.count) - nodes[n].w / 2 }
                }
                layers[r] = resolve(layers[r])
            }
        }
        let minX = nodes.map(\.x).min() ?? 0
        for i in nodes.indices { nodes[i].x += 40 - minX }
        let maxX = nodes.map { $0.x + $0.w }.max() ?? 0
        let maxY = nodes.map { $0.y + $0.h }.max() ?? 0
        return CFGLayout(nodes: nodes, edges: edges, size: CGSize(width: maxX + 120, height: maxY + 60))
    }

    /// True if any two nodes overlap (used by the self-test).
    static func hasOverlap(_ l: CFGLayout) -> Bool {
        for i in l.nodes.indices { for j in (i + 1)..<max(i + 1, l.nodes.count) where l.nodes[i].rect.insetBy(dx: 1, dy: 1).intersects(l.nodes[j].rect) { return true } }
        return false
    }
}

final class CFGView: NSView {
    var layout = CFGLayout(nodes: [], edges: [], size: .zero) { didSet { frame.size = layout.size; needsDisplay = true } }
    var selectedAddr: String? { didSet { needsDisplay = true } }
    var onSelect: ((String) -> Void)?
    var onGoto: ((String) -> Void)?
    override var isFlipped: Bool { true }

    private let kindColors: [NSColor] = [
        Theme.dyn(Theme.rgb(120, 130, 148), Theme.rgb(138, 147, 163)),   // fall
        Theme.dyn(Theme.rgb(42, 111, 219), Theme.rgb(91, 155, 255)),     // jump
        Theme.dyn(Theme.rgb(26, 154, 99), Theme.rgb(76, 195, 138)),      // true
        Theme.dyn(Theme.rgb(201, 54, 66), Theme.rgb(224, 99, 109))]     // false

    override func draw(_ dirtyRect: NSRect) {
        let nodes = layout.nodes
        // edges first
        var lane = 0
        let maxRight = nodes.map { $0.x + $0.w }.max() ?? 0
        for e in layout.edges {
            let s = nodes[e.from], d = nodes[e.to]
            let outs = layout.edges.filter { $0.from == e.from }, ins = layout.edges.filter { $0.to == e.to }
            let ko = outs.firstIndex { $0.to == e.to && $0.kind == e.kind } ?? 0
            let ki = ins.firstIndex { $0.from == e.from && $0.kind == e.kind } ?? 0
            let sx = outs.count > 1 ? s.x + s.w * (0.25 + 0.5 * CGFloat(ko) / CGFloat(outs.count - 1)) : s.x + s.w / 2
            let dx = ins.count > 1 ? d.x + d.w * (0.2 + 0.6 * CGFloat(ki) / CGFloat(ins.count - 1)) : d.x + d.w / 2
            let sy = s.y + s.h, dy = d.y
            let path = NSBezierPath()
            path.move(to: CGPoint(x: sx, y: sy))
            if e.back || dy <= sy {
                let lx = maxRight + 26 + CGFloat(lane % 12) * 9; lane += 1
                path.line(to: CGPoint(x: sx, y: sy + 14)); path.line(to: CGPoint(x: lx, y: sy + 14))
                path.line(to: CGPoint(x: lx, y: dy - 14)); path.line(to: CGPoint(x: dx, y: dy - 14)); path.line(to: CGPoint(x: dx, y: dy))
            } else {
                let m = max(24, (dy - sy) / 2)
                path.curve(to: CGPoint(x: dx, y: dy), controlPoint1: CGPoint(x: sx, y: sy + m), controlPoint2: CGPoint(x: dx, y: dy - m))
            }
            let c = kindColors[min(max(e.kind, 0), 3)]
            c.setStroke(); path.lineWidth = 1.4; path.stroke()
            let arrow = NSBezierPath()
            arrow.move(to: CGPoint(x: dx, y: dy)); arrow.line(to: CGPoint(x: dx - 4.5, y: dy - 8)); arrow.line(to: CGPoint(x: dx + 4.5, y: dy - 8)); arrow.close()
            c.setFill(); arrow.fill()
        }
        // nodes
        for n in nodes where n.rect.intersects(dirtyRect.insetBy(dx: -4, dy: -4)) {
            let r = n.rect
            let box = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            NSColor.controlBackgroundColor.setFill(); box.fill()
            let isEntry = n.index == 0
            (isEntry ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            box.lineWidth = isEntry ? 1.8 : 1; box.stroke()
            for (k, row) in n.rows.enumerated() {
                let ry = r.minY + CFGLayouter.pad + CGFloat(k) * CFGLayouter.rowH
                if row.addr == selectedAddr {
                    Theme.select.setFill()
                    NSRect(x: r.minX + 2, y: ry - 1, width: r.width - 4, height: CFGLayouter.rowH).fill()
                }
                row.text.draw(at: CGPoint(x: r.minX + CFGLayouter.pad, y: ry))
            }
        }
    }

    private func hit(_ p: CGPoint) -> (CFGNode, Int)? {
        for n in layout.nodes where n.rect.contains(p) {
            let k = Int((p.y - n.y - CFGLayouter.pad) / CFGLayouter.rowH)
            if k >= 0 && k < n.rows.count { return (n, k) }
        }
        return nil
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard let (n, k) = hit(p) else { return }
        let row = n.rows[k]
        selectedAddr = row.addr
        onSelect?(row.addr)
        if e.clickCount == 2, let t = row.target { onGoto?(t) }
    }
    override var acceptsFirstResponder: Bool { true }

    func node(containing addr: String) -> CFGNode? { layout.nodes.first { $0.rows.contains { $0.addr == addr } } }
}
