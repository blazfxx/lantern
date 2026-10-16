// Pure rendering: engine JSON -> attributed text. No views here, so it is unit-testable (see SelfTest).
import AppKit

extension NSAttributedString.Key {
    static let ref = NSAttributedString.Key("lantern.ref")     // clickable symbol -> address string
    static let line = NSAttributedString.Key("lantern.line")   // instruction/line address
}

enum Theme {
    static func dyn(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor { NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let fontBold = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)

    static let text    = NSColor.labelColor
    static let dim     = NSColor.tertiaryLabelColor
    static let comment = dyn(rgb(110, 118, 135), rgb(120, 130, 148))
    static let call    = dyn(rgb(180, 95, 6), rgb(229, 163, 90))
    static let jump    = dyn(rgb(26, 127, 90), rgb(127, 200, 169))
    static let ret     = dyn(rgb(192, 57, 43), rgb(224, 108, 117))
    static let reg     = dyn(rgb(123, 63, 178), rgb(199, 146, 234))
    static let imm     = dyn(rgb(31, 95, 191), rgb(130, 170, 255))
    static let string  = dyn(rgb(60, 122, 30), rgb(168, 204, 140))
    static let name    = dyn(rgb(138, 90, 0), rgb(232, 195, 122))
    static let keyword = dyn(rgb(180, 95, 6), rgb(229, 163, 90))
    static let type    = dyn(rgb(26, 127, 90), rgb(127, 200, 169))
    static let patched = dyn(rgb(192, 57, 43), rgb(224, 108, 117))
    static let select  = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35)
    static let paragraph: NSParagraphStyle = { let p = NSMutableParagraphStyle(); p.lineSpacing = 1.5; return p }()
}

struct RenderedText {
    let text: NSAttributedString
    let lineRanges: [String: NSRange]   // address -> character range of that line
    let order: [String]                 // addresses in display order
}

private final class Builder {
    let out = NSMutableAttributedString()
    var ranges: [String: NSRange] = [:]
    var order: [String] = []

    func add(_ s: String, _ color: NSColor = Theme.text, bold: Bool = false, ref: String? = nil, line: String? = nil) {
        var a: [NSAttributedString.Key: Any] = [.font: bold ? Theme.fontBold : Theme.font, .foregroundColor: color, .paragraphStyle: Theme.paragraph]
        if let r = ref { a[.ref] = r }
        if let l = line { a[.line] = l }
        out.append(NSAttributedString(string: s, attributes: a))
    }
    func beginLine() -> Int { out.length }
    func endLine(_ start: Int, addr: String?) {
        add("\n")
        if let a = addr, ranges[a] == nil { ranges[a] = NSRange(location: start, length: out.length - start); order.append(a) }
    }
    func result() -> RenderedText { RenderedText(text: out, lineRanges: ranges, order: order) }
}

enum Syntax {
    static let regRE = try! NSRegularExpression(pattern: #"\b(?:[xw](?:[0-9]|[12][0-9]|30)|sp|xzr|wzr|lr|fp|[vqdsbh](?:[0-9]|[12][0-9]|3[01])|r(?:[abcd]x|[sd]i|[sb]p|8|9|1[0-5])[dwb]?|e(?:[abcd]x|[sd]i|[sb]p)|[abcd][xlh]|[sd]il?|[sb]pl?|rip|eip|[xyz]mm(?:[0-9]|[12][0-9]|3[01]))\b"#)
    static let immRE = try! NSRegularExpression(pattern: #"#?-?0x[0-9a-fA-F]+|#-?\d+\b|\b\d+\b"#)

    static func mnemonicColor(_ m: String) -> NSColor {
        if ["call", "bl", "blr", "blraa", "blrab"].contains(m) { return Theme.call }
        if m.hasPrefix("ret") || m == "eret" || m == "iret" { return Theme.ret }
        if m.hasPrefix("j") || m == "b" || m == "br" || m.hasPrefix("b.") || ["cbz", "cbnz", "tbz", "tbnz"].contains(m) { return Theme.jump }
        return Theme.text
    }

    /// Appends operand text with register/immediate colouring.
    fileprivate static func addOperand(_ b: Builder, _ s: String, line: String?) {
        let ns = s as NSString
        var marks: [(NSRange, NSColor)] = []
        for m in regRE.matches(in: s, range: NSRange(location: 0, length: ns.length)) { marks.append((m.range, Theme.reg)) }
        for m in immRE.matches(in: s, range: NSRange(location: 0, length: ns.length)) { marks.append((m.range, Theme.imm)) }
        marks.sort { $0.0.location < $1.0.location }
        var pos = 0
        for (r, c) in marks where r.location >= pos {
            if r.location > pos { b.add(ns.substring(with: NSRange(location: pos, length: r.location - pos)), line: line) }
            b.add(ns.substring(with: r), c, line: line)
            pos = r.location + r.length
        }
        if pos < ns.length { b.add(ns.substring(from: pos), line: line) }
    }
}

enum AssemblyRenderer {
    fileprivate static func insnLine(_ b: Builder, _ i: Insn, showBytes: Bool) {
        let start = b.beginLine()
        let addr = String(i.a.dropFirst(2))
        b.add(String(repeating: "0", count: max(0, 16 - addr.count)) + addr + "  ", i.p == true ? Theme.patched : Theme.dim, line: i.a)
        if showBytes { b.add(i.b.padding(toLength: 24, withPad: " ", startingAt: 0) + " ", i.p == true ? Theme.patched : Theme.dim, line: i.a) }
        b.add(i.m, Syntax.mnemonicColor(i.m), bold: true, line: i.a)
        if !i.o.isEmpty {
            b.add(" ", line: i.a)
            for p in i.o {
                if let r = p.a { b.add(p.t, Theme.name, ref: r, line: i.a) } else { Syntax.addOperand(b, p.t, line: i.a) }
            }
        }
        if !i.c.isEmpty {
            b.add("   ; ", Theme.comment, line: i.a)
            for p in i.c { b.add(p.t, p.a != nil ? Theme.string : Theme.comment, ref: p.a, line: i.a) }
        }
        b.endLine(start, addr: i.a)
    }

    static func render(_ f: FuncDetail, showBytes: Bool) -> RenderedText {
        let b = Builder()
        var head = "; \(f.n)  [\(f.a) - \(f.end))  \(f.size) bytes, \(f.blocks.count) blocks"
        if f.noret { head += ", noreturn" }
        if f.thunk { head += ", thunk" }
        b.add(head + "\n", Theme.comment)
        if !f.xrefs.isEmpty {
            b.add("; XREFS: ", Theme.comment)
            for x in f.xrefs.prefix(6) { b.add(x.n, Theme.comment, ref: x.a); b.add("(\(x.t)) ", Theme.comment) }
            if f.xrefs.count > 6 { b.add("… +\(f.xrefs.count - 6)", Theme.comment) }
            b.add("\n", Theme.comment)
        }
        for (bi, blk) in f.blocks.enumerated() {
            if !blk.label.isEmpty {
                let start = b.beginLine()
                b.add(blk.label + ":", Theme.name, bold: true, ref: blk.a, line: blk.a)
                if bi > 0 && !blk.from.isEmpty { b.add("    ; from " + blk.from.joined(separator: " "), Theme.comment, line: blk.a) }
                b.endLine(start, addr: nil)
            }
            for i in blk.insns { insnLine(b, i, showBytes: showBytes) }
        }
        return b.result()
    }

    static func render(_ l: LinearListing, at start: String, showBytes: Bool) -> RenderedText {
        let b = Builder()
        b.add("; linear listing at \(start) (not inside a function)\n", Theme.comment)
        for i in l.insns {
            if let lab = i.label { b.add(lab + ":\n", Theme.name, bold: true, ref: i.a) }
            insnLine(b, i, showBytes: showBytes)
        }
        return b.result()
    }
}

enum PseudoRenderer {
    static func color(_ c: String) -> NSColor {
        switch c {
        case "k": return Theme.keyword
        case "d": return Theme.type
        case "n": return Theme.imm
        case "s": return Theme.string
        case "r": return Theme.name
        case "c": return Theme.comment
        default: return Theme.text
        }
    }
    static func render(_ p: PseudoResult) -> RenderedText {
        let b = Builder()
        for (idx, l) in p.lines.enumerated() {
            let start = b.beginLine()
            b.add(String(repeating: " ", count: l.i * 4))
            for part in l.p { b.add(part.t, color(part.c), bold: part.c == "k", ref: part.a) }
            b.endLine(start, addr: "L\(idx)")
        }
        return b.result()
    }
    static func plainText(_ p: PseudoResult) -> String {
        p.lines.map { String(repeating: " ", count: $0.i * 4) + $0.p.map(\.t).joined() }.joined(separator: "\n")
    }
}

enum HexRenderer {
    static func bytes(_ hex: String) -> [UInt8] {
        let chars = Array(hex)
        return stride(from: 0, to: chars.count - 1, by: 2).compactMap { UInt8(String(chars[$0...$0 + 1]), radix: 16) }
    }
    static func render(_ h: HexResult) -> RenderedText {
        let b = Builder()
        let base = UInt64(h.a.dropFirst(2), radix: 16) ?? 0
        let data = bytes(h.hex)
        b.add("; \(h.n)\n", Theme.comment)
        for row in stride(from: 0, to: data.count, by: 16) {
            let start = b.beginLine()
            let addr = String(base + UInt64(row), radix: 16)
            let a = "0x" + addr
            b.add(String(repeating: "0", count: max(0, 14 - addr.count)) + addr + "  ", Theme.dim, line: a)
            var asc = ""
            for k in 0..<16 {
                if row + k < data.count {
                    let v = data[row + k]
                    b.add(String(format: "%02x ", v), v == 0 ? Theme.dim : Theme.text, line: a)
                    asc += (v >= 32 && v < 127) ? String(UnicodeScalar(v)) : "."
                } else { b.add("   ", line: a) }
                if k == 7 { b.add(" ", line: a) }
            }
            b.add(" |" + asc + "|", Theme.string, line: a)
            b.endLine(start, addr: a)
        }
        return b.result()
    }
}

// Compact per-block text used inside CFG nodes: one attributed string per line + the address it belongs to.
extension AssemblyRenderer {
    static func nodeLines(_ blk: Block, showLabel: Bool) -> [(addr: String, text: NSAttributedString, target: String?)] {
        var rows: [(String, NSAttributedString, String?)] = []
        func attrs(_ c: NSColor, bold: Bool = false) -> [NSAttributedString.Key: Any] {
            [.font: bold ? Theme.fontBold : Theme.font, .foregroundColor: c]
        }
        if showLabel && !blk.label.isEmpty {
            rows.append((blk.a, NSAttributedString(string: blk.label + ":", attributes: attrs(Theme.name, bold: true)), nil))
        }
        for i in blk.insns {
            let s = NSMutableAttributedString()
            let a = String(i.a.dropFirst(2))
            s.append(NSAttributedString(string: String(String(repeating: "0", count: max(0, 8 - a.count)) + a.suffix(8)) + " ", attributes: attrs(Theme.dim)))
            s.append(NSAttributedString(string: i.m, attributes: attrs(Syntax.mnemonicColor(i.m), bold: true)))
            var target: String? = nil
            if !i.o.isEmpty {
                s.append(NSAttributedString(string: " ", attributes: attrs(Theme.text)))
                for p in i.o {
                    if let r = p.a { s.append(NSAttributedString(string: p.t, attributes: attrs(Theme.name))); target = target ?? r }
                    else { s.append(NSAttributedString(string: p.t, attributes: attrs(Theme.text))) }
                }
            }
            if !i.c.isEmpty {
                s.append(NSAttributedString(string: "  ; " + i.c.map(\.t).joined(), attributes: attrs(Theme.comment)))
                if target == nil { target = i.c.compactMap(\.a).first }
            }
            rows.append((i.a, s, target))
        }
        return rows
    }
}
