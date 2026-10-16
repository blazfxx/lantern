// `Lantern --self-test <binary> [--arch <arch>]`: end-to-end check of the engine bridge and every
// non-GUI piece (renderers, CFG layout + offscreen drawing, data inspector, edits, patching). Exit 0 = all pass.
import AppKit

enum SelfTest {
    static var failures = 0
    static var stage = "start"
    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print((ok ? "  PASS  " : "  FAIL  ") + name + (detail.isEmpty ? "" : "  — " + detail))
        if !ok { failures += 1 }
    }

    static func run(_ args: [String]) -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let i = args.firstIndex(of: "--self-test"), i + 1 < args.count else {
            print("usage: Lantern --self-test <binary> [--arch <arch>]"); return 2
        }
        let binary = args[i + 1]
        var arch: String? = nil
        if let a = args.firstIndex(of: "--arch"), a + 1 < args.count { arch = args[a + 1] }
        _ = NSApplication.shared

        guard EngineProcess.binaryPath != nil else { print("engine not found (set LANTERN_ENGINE)"); return 2 }
        print("Lantern self-test · engine \(EngineProcess.version) · \(binary)")

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lantern-selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let db = tmp.appendingPathComponent("t.erdb")
        var oargs = ["open", binary, "-o", db.path, "-q"]; if let a = arch { oargs += ["--arch", a] }
        let r = EngineProcess.run(oargs)
        check("analysis succeeds", r.status == 0, r.err.trimmingCharacters(in: .whitespacesAndNewlines))
        if r.status != 0 { return 1 }

        let engine = EngineProcess()
        let sem = DispatchSemaphore(value: 0)
        var base: URL?
        engine.start(database: db) { if case .success(let u) = $0 { base = u }; sem.signal() }
        sem.wait()
        defer { engine.stop() }
        check("engine server starts", base != nil)
        guard let url = base else { return 1 }
        let api = EngineAPI(base: url)

        do {
            // --- info / lists
            stage = "info/lists"
            let info = try awaitSync { try await api.info() }
            check("info: functions found", info.funcs > 0, "\(info.funcs) procedures, \(info.insns) instructions")
            let funcs = try awaitSync { try await api.funcs("") }
            check("procedure list", funcs.total > 0 && !funcs.items.isEmpty)
            _ = try awaitSync { try await api.list("strings", "") }
            let names = try awaitSync { try await api.list("names", "") }
            check("name list", names.total > 0)

            // --- pick a real (non-thunk) function, prefer the entry
            stage = "function detail"
            let target = info.entry.isEmpty ? (funcs.items.first { !$0.t }?.a ?? funcs.items[0].a) : info.entry
            let f = try awaitSync { try await api.function(target) }
            check("function detail", !f.blocks.isEmpty, "\(f.n): \(f.blocks.count) blocks")

            // --- assembly renderer
            stage = "assembly render"
            let insnCount = f.blocks.reduce(0) { $0 + $1.insns.count }
            let asm = AssemblyRenderer.render(f, showBytes: true)
            check("assembly: every instruction has a line", asm.lineRanges.count >= insnCount && asm.text.length > 0, "\(insnCount) instructions")
            check("assembly: clickable symbols present", containsAttribute(asm.text, .ref))
            let (sv, tv) = CodeView.make(); _ = sv
            tv.show(asm)
            check("text view shows rendering", (tv.textStorage?.length ?? 0) == asm.text.length)

            // --- control-flow graph
            stage = "cfg"
            let layout = CFGLayouter.layout(f)
            check("cfg: one node per block", layout.nodes.count == f.blocks.count)
            check("cfg: no overlapping nodes", !CFGLayouter.hasOverlap(layout))
            check("cfg: positive size", layout.size.width > 0 && layout.size.height > 0)
            let cv = CFGView(); cv.frame = NSRect(origin: .zero, size: layout.size); cv.layout = layout
            if let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) {
                cv.cacheDisplay(in: cv.bounds, to: rep)
                var drawn = false
                outer: for y in stride(from: 0, to: rep.pixelsHigh, by: max(1, rep.pixelsHigh / 60)) {
                    for x in stride(from: 0, to: rep.pixelsWide, by: max(1, rep.pixelsWide / 60)) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { drawn = true; break outer }
                }
                check("cfg: draws pixels", drawn)
            } else { check("cfg: offscreen bitmap", false) }

            // --- pseudo-code (may be unsupported for exotic arches)
            stage = "pseudo"
            if let p = try? awaitSync({ try await api.pseudo(f.a) }) {
                let pr = PseudoRenderer.render(p)
                check("pseudo-code renders", !p.lines.isEmpty && pr.text.length > 0, "\(p.lines.count) lines")
                check("pseudo-code has a signature", PseudoRenderer.plainText(p).contains("("))
            } else { check("pseudo-code (skipped: not available for this function)", true) }

            // --- hex + data inspector
            stage = "hex"
            let h = try awaitSync { try await api.hex(f.a, n: 64) }
            let hr = HexRenderer.render(h)
            check("hex: rows rendered", hr.order.count >= 3, "\(hr.order.count) rows")
            let di = DataInspector.describe(addr: h.a, hex: String(h.hex.prefix(32)))
            check("data inspector decodes integers", di.contains("uint32") && di.contains("int64"))

            // --- xrefs / where / find
            stage = "xrefs/where/find"
            let w = try awaitSync { try await api.whereIs(f.a) }
            check("where resolves function start", w.func == f.a)
            let xr = try awaitSync { try await api.xrefs(f.a) }
            check("xrefs call succeeds", xr.a == f.a)
            let firstBytes = String(h.hex.prefix(16)).enumerated().reduce("") { $0 + ($1.offset % 2 == 0 && $1.offset > 0 ? " " : "") + String($1.element) }
            let fnd = try awaitSync { try await api.find(hex: firstBytes) }
            check("byte search finds the function bytes", fnd.items.contains { $0.a == f.a })

            // --- edits: rename + comment round trip
            stage = "rename/comment"
            let originalName = f.n
            _ = try awaitSync { try await api.rename(f.a, "lantern_selftest_fn") }
            let renamed = try awaitSync { try await api.function(f.a) }
            check("rename takes effect", renamed.n == "lantern_selftest_fn")
            _ = try awaitSync { try await api.rename(f.a, "") }
            let restored = try awaitSync { try await api.function(f.a) }
            check("rename can be cleared", restored.n == originalName || restored.n.hasPrefix("sub_"), restored.n)
            let firstInsn = f.blocks[0].insns[0].a
            _ = try awaitSync { try await api.comment(firstInsn, "self-test comment") }
            let commented = try awaitSync { try await api.function(f.a) }
            check("comment appears in listing", commented.blocks[0].insns[0].c.contains { $0.t.contains("self-test comment") })

            // --- patching round trip (write identical bytes: reversible and content-neutral)
            stage = "patch/unpatch"
            let hb = try awaitSync { try await api.hex(firstInsn, n: 4) }
            _ = try awaitSync { try await api.patch(firstInsn, hex: hb.hex) }
            let p1 = try awaitSync { try await api.patches() }
            check("patch recorded", p1.items.count == 1)
            _ = try awaitSync { try await api.unpatch(firstInsn) }
            let p2 = try awaitSync { try await api.patches() }
            check("patch reverted", p2.items.isEmpty)
        } catch {
            check("no unexpected errors", false, "during \(stage): \(error.localizedDescription)")
        }

        print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
        return failures == 0 ? 0 : 1
    }

    private static func containsAttribute(_ s: NSAttributedString, _ key: NSAttributedString.Key) -> Bool {
        var found = false
        s.enumerateAttribute(key, in: NSRange(location: 0, length: s.length)) { v, _, stop in if v != nil { found = true; stop.pointee = true } }
        return found
    }
}
