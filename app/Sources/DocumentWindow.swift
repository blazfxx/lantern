// One window per analysed binary: sidebar | (Assembly · Graph · Pseudo · Hex) over an inspector.
import AppKit

enum Mode: Int { case assembly, graph, pseudo, hex }

@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    let source: URL
    let api: EngineAPI
    let engine: EngineProcess
    let databaseURL: URL
    var onClose: ((DocumentWindowController) -> Void)?

    private(set) var info: BinaryInfo?
    private let sidebar = SidebarViewController()
    private let inspector = InspectorViewController()
    private let palette = PalettePanel()
    private let status = NSTextField(labelWithString: "")
    private var asmScroll: NSScrollView, asmView: CodeTextView
    private var pseudoScroll: NSScrollView, pseudoView: CodeTextView
    private var hexScroll: NSScrollView, hexView: CodeTextView
    private let cfgScroll = NSScrollView()
    private let cfgView = CFGView()
    private let container = NSView()
    private var modeControl = NSSegmentedControl(labels: ["Assembly", "Graph", "Pseudo", "Hex"], trackingMode: .selectOne, target: nil, action: nil)
    private var navControl = NSSegmentedControl(images: [NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!,
                                                         NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")!],
                                                trackingMode: .momentary, target: nil, action: nil)

    // navigation state
    private(set) var mode: Mode = .assembly
    private var current: FuncDetail?
    private var currentLoc: String?              // selected address
    private var rendered: RenderedText?
    private var pseudoFor: String?
    private var cfgFor: String?
    private var history: [String] = [], forwardStack: [String] = []
    private var showBytes = false
    private var hover: String?

    init(source: URL, database: URL, engine: EngineProcess, api: EngineAPI) {
        self.source = source; self.databaseURL = database; self.engine = engine; self.api = api
        (asmScroll, asmView) = CodeView.make()
        (pseudoScroll, pseudoView) = CodeView.make()
        (hexScroll, hexView) = CodeView.make()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 880),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = source.lastPathComponent
        win.subtitle = "Loading…"
        win.representedURL = source
        win.minSize = NSSize(width: 980, height: 560)
        win.setFrameAutosaveName("LanternDocument")
        super.init(window: win)
        win.delegate = self
        buildLayout()
        wire()
        buildToolbar()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: layout

    private func buildLayout() {
        let split = NSSplitViewController()
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        let sItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sItem.minimumThickness = 220; sItem.maximumThickness = 460
        split.addSplitViewItem(sItem)

        let mainVC = NSViewController()
        let main = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.translatesAutoresizingMaskIntoConstraints = false
        let bar = NSVisualEffectView(); bar.material = .titlebar; bar.blendingMode = .withinWindow
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(status)
        main.addSubview(container); main.addSubview(bar)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: main.topAnchor), container.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: main.trailingAnchor), container.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: main.leadingAnchor), bar.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: main.bottomAnchor), bar.heightAnchor.constraint(equalToConstant: 22),
            status.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10), status.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            status.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        cfgScroll.documentView = cfgView
        cfgScroll.hasVerticalScroller = true; cfgScroll.hasHorizontalScroller = true; cfgScroll.autohidesScrollers = true
        cfgScroll.allowsMagnification = true; cfgScroll.minMagnification = 0.1; cfgScroll.maxMagnification = 3
        cfgScroll.drawsBackground = true; cfgScroll.backgroundColor = .textBackgroundColor
        for v in [asmScroll, cfgScroll, pseudoScroll, hexScroll] {
            v.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(v)
            NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo: container.topAnchor), v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                                         v.leadingAnchor.constraint(equalTo: container.leadingAnchor), v.trailingAnchor.constraint(equalTo: container.trailingAnchor)])
        }
        mainVC.view = main

        let right = NSSplitViewController()
        right.splitView.isVertical = false
        right.addSplitViewItem(NSSplitViewItem(viewController: mainVC))
        let inspItem = NSSplitViewItem(viewController: inspector)
        inspItem.minimumThickness = 120; inspItem.canCollapse = true
        right.addSplitViewItem(inspItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: right))
        window?.contentViewController = split
        window?.setContentSize(NSSize(width: 1400, height: 880))
        setMode(.assembly, animate: false)
    }

    private func wire() {
        sidebar.fetch = { [weak self] kind, q in await self?.fetchSidebar(kind, q) ?? [] }
        sidebar.onSelect = { [weak self] a in self?.goto(a) }
        inspector.onGoto = { [weak self] a in self?.goto(a) }
        for tv in [asmView, pseudoView, hexView] {
            tv.onRef = { [weak self] a in self?.goto(a) }
            tv.onHover = { [weak self] a in self?.hover = a }
            tv.onKey = { [weak self] k in self?.handleKey(k) ?? false }
        }
        asmView.onLine = { [weak self] a in self?.select(a) }
        hexView.onLine = { [weak self] a in self?.select(a) }
        cfgView.onSelect = { [weak self] a in self?.select(a) }
        cfgView.onGoto = { [weak self] a in self?.goto(a) }
        palette.search = { [weak self] q in await self?.paletteSearch(q) ?? [] }
        palette.commands = paletteCommands()
    }

    // MARK: toolbar

    private func buildToolbar() {
        let tb = NSToolbar(identifier: "LanternToolbar")
        tb.delegate = self; tb.displayMode = .iconOnly
        window?.toolbar = tb; window?.toolbarStyle = .unified
        modeControl.selectedSegment = 0; modeControl.target = self; modeControl.action = #selector(modeChanged)
        navControl.target = self; navControl.action = #selector(navChanged)
    }
    private static let tbBack = NSToolbarItem.Identifier("nav"), tbMode = NSToolbarItem.Identifier("mode"), tbPalette = NSToolbarItem.Identifier("palette")
    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.tbBack, .flexibleSpace, Self.tbMode, .flexibleSpace, Self.tbPalette] }
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(t) }
    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case Self.tbBack: item.view = navControl; item.label = "Back / Forward"
        case Self.tbMode: item.view = modeControl; item.label = "View"
        case Self.tbPalette:
            item.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Command palette")
            item.label = "Search"; item.target = self; item.action = #selector(showPalette); item.toolTip = "Command palette (⇧⌘P)"
        default: return nil
        }
        return item
    }
    @objc private func modeChanged() { setMode(Mode(rawValue: modeControl.selectedSegment) ?? .assembly) }
    @objc private func navChanged() { navControl.selectedSegment == 0 ? goBack() : goForward() }

    // MARK: startup

    func load() async {
        do {
            let i = try await api.info()
            info = i
            window?.subtitle = "\(i.format) · \(i.arch) · \(i.funcs) procedures"
            sidebar.reload()
            let pct = i.codeBytes > 0 ? Double(i.covered) / Double(i.codeBytes) * 100 : 0
            status.stringValue = String(format: "%d procedures · %d blocks · %d instructions · %d xrefs · %d strings · %.1f%% of code explored", i.funcs, i.blocks, i.insns, i.xrefs, i.strings, pct)
            await navigate(i.entry.isEmpty ? (i.segments.first?.a ?? "0x0") : i.entry, push: false)
            if let m = ProcessInfo.processInfo.environment["LANTERN_START_MODE"] {   // used for screenshots/tests
                switch m { case "graph": setMode(.graph); case "pseudo": setMode(.pseudo); case "hex": setMode(.hex); default: break }
            }
            await refreshPatches()
        } catch { fail(error) }
    }

    // MARK: navigation

    func goto(_ loc: String) { Task { await navigate(loc, push: true) } }

    func navigate(_ loc: String, push: Bool) async {
        do {
            let w = try await api.whereIs(loc)
            if push, let cur = currentLoc, cur != w.a { history.append(cur); forwardStack.removeAll() }
            currentLoc = w.a
            if !w.func.isEmpty {
                if current?.a != w.func { try await loadFunction(w.func) }
            } else {
                current = nil
                let l = try await api.linear(w.a)
                let r = AssemblyRenderer.render(l, at: w.a, showBytes: showBytes)
                rendered = r; asmView.show(r); pseudoFor = nil; cfgFor = nil
                if mode == .graph || mode == .pseudo { setMode(.assembly) }
            }
            reveal(w.a)
            await updateSide(w.a, name: w.n)
        } catch { fail(error) }
    }

    private func loadFunction(_ a: String) async throws {
        let f = try await api.function(a)
        current = f; pseudoFor = nil; cfgFor = nil
        let r = AssemblyRenderer.render(f, showBytes: showBytes)
        rendered = r; asmView.show(r)
        sidebar.highlight(f.a)
        if mode == .graph { showGraph() }
        if mode == .pseudo { await showPseudo() }
    }

    private func reveal(_ addr: String) {
        asmView.reveal(addr)
        if mode == .graph, let n = cfgView.node(containing: addr) {
            cfgView.selectedAddr = addr
            cfgScroll.contentView.scroll(to: NSPoint(x: max(0, n.x - 60), y: max(0, n.y - 80)))
            cfgScroll.reflectScrolledClipView(cfgScroll.contentView)
        }
        if mode == .hex { Task { await showHex(addr) } }
    }

    private func select(_ addr: String) {
        currentLoc = addr
        Task { await updateSide(addr, name: nil) }
    }

    private func updateSide(_ addr: String, name: String?) async {
        window?.title = source.lastPathComponent
        if let r = try? await api.xrefs(addr) { inspector.showXrefs(r); window?.subtitle = "\(addr)  \(r.n)" }
        if let h = try? await api.hex(addr, n: 16) { inspector.showData(addr: addr, hex: h.hex) }
    }

    func goBack() {
        guard let prev = history.popLast() else { return }
        if let c = currentLoc { forwardStack.append(c) }
        Task { await navigate(prev, push: false) }
    }
    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let c = currentLoc { history.append(c) }
        Task { await navigate(next, push: false) }
    }

    // MARK: modes

    func setMode(_ m: Mode, animate: Bool = true) {
        mode = m
        modeControl.selectedSegment = m.rawValue
        asmScroll.isHidden = m != .assembly; cfgScroll.isHidden = m != .graph
        pseudoScroll.isHidden = m != .pseudo; hexScroll.isHidden = m != .hex
        switch m {
        case .assembly: window?.makeFirstResponder(asmView); if let a = currentLoc { asmView.reveal(a) }
        case .graph: showGraph(); window?.makeFirstResponder(cfgView)
        case .pseudo: Task { await showPseudo() }; window?.makeFirstResponder(pseudoView)
        case .hex: Task { await showHex(currentLoc ?? "0x0") }; window?.makeFirstResponder(hexView)
        }
    }

    private func showGraph() {
        guard let f = current else { cfgView.layout = CFGLayout(nodes: [], edges: [], size: .zero); return }
        if cfgFor != f.a {
            cfgView.layout = CFGLayouter.layout(f); cfgFor = f.a
            DispatchQueue.main.async { [weak self] in self?.fitGraph() }
        }
        if let a = currentLoc { cfgView.selectedAddr = a }
    }

    /// Fit the whole graph in view (never magnifies beyond 100%).
    @objc func fitGraph(_ s: Any? = nil) {
        let size = cfgView.layout.size, vis = cfgScroll.contentSize
        guard size.width > 0, size.height > 0, vis.width > 0 else { return }
        cfgScroll.magnification = max(cfgScroll.minMagnification, min(1, vis.width / size.width, vis.height / size.height))
        cfgScroll.contentView.scroll(to: .zero); cfgScroll.reflectScrolledClipView(cfgScroll.contentView)
    }

    private func showPseudo() async {
        guard let f = current else {
            pseudoView.show(RenderedText(text: NSAttributedString(string: "Not inside a procedure.", attributes: [.font: Theme.font, .foregroundColor: Theme.comment]), lineRanges: [:], order: []))
            return
        }
        if pseudoFor == f.a { return }
        do {
            let p = try await api.pseudo(f.a)
            pseudoView.show(PseudoRenderer.render(p)); pseudoFor = f.a
        } catch {
            pseudoView.show(RenderedText(text: NSAttributedString(string: "Decompiler: \(error.localizedDescription)", attributes: [.font: Theme.font, .foregroundColor: Theme.comment]), lineRanges: [:], order: []))
            pseudoFor = nil
        }
    }

    private func showHex(_ addr: String) async {
        if let h = try? await api.hex(addr, n: 1024) { hexView.show(HexRenderer.render(h)) }
    }

    // MARK: keyboard (plain keys inside the listings, in the spirit of classic disassemblers)

    func handleKey(_ k: String) -> Bool {
        switch k {
        case "n": renameAction(nil)
        case ";": commentAction(nil)
        case "x": inspector.select("xrefs")
        case " ": toggleGraph(nil)
        case "\t": togglePseudo(nil)
        case "g": gotoAction(nil)
        case "p": patchAction(nil)
        case "a": assembleAction(nil)
        case "u": revertAction(nil)
        case "b": toggleBytes(nil)
        case "f": fitGraph()
        case "/": window?.makeFirstResponder(sidebar.search)
        default: return false
        }
        return true
    }

    // MARK: actions (menu + keys)

    @objc func toggleGraph(_ s: Any?) { setMode(mode == .graph ? .assembly : .graph) }
    @objc func togglePseudo(_ s: Any?) { setMode(mode == .pseudo ? .assembly : .pseudo) }
    @objc func showAssembly(_ s: Any?) { setMode(.assembly) }
    @objc func showGraphMode(_ s: Any?) { setMode(.graph) }
    @objc func showPseudoMode(_ s: Any?) { setMode(.pseudo) }
    @objc func showHexMode(_ s: Any?) { setMode(.hex) }
    @objc func goBackAction(_ s: Any?) { goBack() }
    @objc func goForwardAction(_ s: Any?) { goForward() }
    @objc func showPalette(_ s: Any?) { if let w = window { palette.present(over: w) } }
    @objc func focusFilter(_ s: Any?) { window?.makeFirstResponder(sidebar.search) }
    @objc func toggleBytes(_ s: Any?) {
        showBytes.toggle()
        if let f = current { let r = AssemblyRenderer.render(f, showBytes: showBytes); rendered = r; asmView.show(r); if let a = currentLoc { asmView.reveal(a) } }
    }
    @objc func copyPseudo(_ s: Any?) {
        guard let f = current else { return }
        let api = self.api
        guard let p = try? awaitSync({ try await api.pseudo(f.a) }) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(PseudoRenderer.plainText(p), forType: .string)
    }

    @objc func gotoAction(_ s: Any?) {
        Task { if let v = await ask("Go to", "Address (hex) or name", ""), !v.isEmpty { await navigate(v.trimmingCharacters(in: .whitespaces), push: true) } }
    }
    @objc func renameAction(_ s: Any?) {
        guard let target = hover ?? currentLoc else { return }
        Task {
            let cur = (try? await api.whereIs(target))?.n ?? target
            guard let v = await ask("Rename", "\(target)   (current: \(cur))", cur.components(separatedBy: "+").first ?? cur) else { return }
            await edit { try await self.api.rename(target, v.trimmingCharacters(in: .whitespaces)) }
        }
    }
    @objc func commentAction(_ s: Any?) {
        guard let a = currentLoc else { return }
        Task { if let v = await ask("Comment", a, "") { await edit { try await self.api.comment(a, v) } } }
    }
    @objc func patchAction(_ s: Any?) {
        guard let a = currentLoc else { return }
        Task {
            let cur = (try? await api.hex(a, n: 4))?.hex ?? ""
            if let v = await ask("Patch bytes", "\(a)   (hex; currently \(cur))", cur) { await edit { try await self.api.patch(a, hex: v) } }
        }
    }
    @objc func assembleAction(_ s: Any?) {
        guard let a = currentLoc else { return }
        Task { if let v = await ask("Assemble", "\(a)  replaces the instruction here (nop-padded)", ""), !v.isEmpty { await edit { try await self.api.assemble(a, v) } } }
    }
    @objc func revertAction(_ s: Any?) {
        guard let a = currentLoc else { return }
        Task { await edit { try await self.api.unpatch(a) } }
    }
    @objc func reanalyzeAction(_ s: Any?) {
        Task { await edit { try await self.api.reanalyze() }; if let i = try? await api.info() { info = i } }
    }
    @objc func exportAction(_ s: Any?) {
        guard let w = window else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + ".patched"
        p.message = "Write the patched binary (Mach-O output is ad-hoc signed)"
        p.beginSheetModal(for: w) { [weak self] r in
            guard r == .OK, let url = p.url, let self = self else { return }
            Task { await self.edit { try await self.api.export(url.path, sign: true) } }
        }
    }
    @objc func revealDatabase(_ s: Any?) { NSWorkspace.shared.activateFileViewerSelecting([databaseURL]) }

    /// Runs an edit, then reloads whatever is on screen.
    private func edit<T>(_ op: @escaping () async throws -> T) async {
        do {
            _ = try await op()
            let loc = currentLoc
            let was = current?.a
            current = nil; pseudoFor = nil; cfgFor = nil
            sidebar.reload()
            if let l = loc { await navigate(l, push: false) } else if let w = was { await navigate(w, push: false) }
            await refreshPatches()
        } catch { fail(error) }
    }
    private func refreshPatches() async { if let p = try? await api.patches() { inspector.showPatches(p) } }

    func menuItemValidates(_ item: NSMenuItem) -> Bool { true }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(showAssembly(_:)): item.state = mode == .assembly ? .on : .off
        case #selector(showGraphMode(_:)): item.state = mode == .graph ? .on : .off
        case #selector(showPseudoMode(_:)): item.state = mode == .pseudo ? .on : .off
        case #selector(showHexMode(_:)): item.state = mode == .hex ? .on : .off
        case #selector(toggleBytes(_:)): item.state = showBytes ? .on : .off
        case #selector(goBackAction(_:)): return !history.isEmpty
        case #selector(goForwardAction(_:)): return !forwardStack.isEmpty
        default: break
        }
        return true
    }

    // MARK: palette

    private func paletteCommands() -> [PaletteEntry] {
        [PaletteEntry(title: "Go to…", detail: "G") { [weak self] in self?.gotoAction(nil) },
         PaletteEntry(title: "Show Assembly", detail: "⌘1") { [weak self] in self?.setMode(.assembly) },
         PaletteEntry(title: "Show Control-Flow Graph", detail: "⌘2 / Space") { [weak self] in self?.setMode(.graph) },
         PaletteEntry(title: "Show Pseudo-code", detail: "⌘3 / Tab") { [weak self] in self?.setMode(.pseudo) },
         PaletteEntry(title: "Show Hex", detail: "⌘4") { [weak self] in self?.setMode(.hex) },
         PaletteEntry(title: "Rename", detail: "N") { [weak self] in self?.renameAction(nil) },
         PaletteEntry(title: "Add Comment", detail: ";") { [weak self] in self?.commentAction(nil) },
         PaletteEntry(title: "Assemble Instruction…", detail: "A") { [weak self] in self?.assembleAction(nil) },
         PaletteEntry(title: "Patch Bytes…", detail: "P") { [weak self] in self?.patchAction(nil) },
         PaletteEntry(title: "Export Patched Binary…", detail: "") { [weak self] in self?.exportAction(nil) },
         PaletteEntry(title: "Re-analyse", detail: "") { [weak self] in self?.reanalyzeAction(nil) }]
    }

    private func paletteSearch(_ q: String) async -> [PaletteEntry] {
        var out: [PaletteEntry] = []
        if q.lowercased().hasPrefix("0x") || (q.count >= 4 && q.allSatisfy { $0.isHexDigit }) {
            out.append(PaletteEntry(title: "Go to \(q)", detail: "address") { [weak self] in self?.goto(q) })
        }
        if let f = try? await api.funcs(q, limit: 12) {
            out += f.items.map { it in PaletteEntry(title: it.n, detail: "procedure · \(it.a)") { [weak self] in self?.goto(it.a) } }
        }
        if let n = try? await api.list("names", q) {
            out += n.items.prefix(8).map { it in PaletteEntry(title: it.n, detail: "name · \(it.a)") { [weak self] in self?.goto(it.a) } }
        }
        if let s = try? await api.list("strings", q) {
            out += s.items.prefix(5).map { it in PaletteEntry(title: "“\(it.n)”", detail: "string · \(it.a)") { [weak self] in self?.goto(it.a) } }
        }
        return out
    }

    private func fetchSidebar(_ kind: SidebarViewController.Kind, _ q: String) async -> [SidebarItem] {
        do {
            if kind == .procs {
                let r = try await api.funcs(q)
                return r.items.map { SidebarItem(addr: $0.a, name: $0.n, info: $0.t ? "thunk" : ($0.r ? "noreturn" : "\($0.s) B")) }
            }
            let r = try await api.list(kind.api, q)
            return r.items.map { SidebarItem(addr: $0.a, name: $0.n, info: $0.x ?? "") }
        } catch { return [] }
    }

    // MARK: dialogs / errors

    func ask(_ title: String, _ message: String, _ initial: String) async -> String? {
        guard let w = window else { return nil }
        let a = NSAlert()
        a.messageText = title; a.informativeText = message
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        f.stringValue = initial; f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        a.accessoryView = f
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        return await withCheckedContinuation { cont in
            a.beginSheetModal(for: w) { r in cont.resume(returning: r == .alertFirstButtonReturn ? f.stringValue : nil) }
        }
    }

    func fail(_ error: Error) {
        guard let w = window else { return }
        let a = NSAlert(); a.alertStyle = .warning
        a.messageText = "Something went wrong"; a.informativeText = error.localizedDescription
        a.beginSheetModal(for: w)
    }

    func windowWillClose(_ notification: Notification) { engine.stop(); onClose?(self) }
}

// Helper for synchronous call sites (clipboard copy, headless self-test): run an async op to completion off the main actor.
private final class ResultBox<T>: @unchecked Sendable { var value: Result<T, Error>? }

func awaitSync<T>(_ op: @escaping @Sendable () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task.detached {
        do { box.value = .success(try await op()) } catch { box.value = .failure(error) }
        sem.signal()
    }
    sem.wait()
    return try box.value!.get()
}
