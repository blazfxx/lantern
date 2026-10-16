// App shell: menus, welcome window, opening binaries (analysis + cached databases), recents.
import AppKit

enum Paths {
    static var databases: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Lantern/Databases", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    /// path + size + mtime + arch + engine version, so edits or engine upgrades re-analyse.
    static func database(for file: URL, arch: String?) -> URL {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: file.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        var h: UInt64 = 0xcbf29ce484222325
        for b in "\(file.path)|\(size)|\(mtime)|\(arch ?? "")|\(EngineProcess.version)".utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return databases.appendingPathComponent("\(file.deletingPathExtension().lastPathComponent)-\(String(h, radix: 16)).erdb")
    }
    /// For an .app bundle, the main executable inside it; otherwise the file itself.
    static func executable(of url: URL) -> URL {
        guard url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url), let exe = bundle.executableURL else { return url }
        return exe
    }
    static func fatArchitectures(_ file: URL) -> [String] {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/lipo"); p.arguments = ["-archs", executable(of: file).path]
        let o = Pipe(); p.standardOutput = o; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let d = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { return [] }
        let a = String(decoding: d, as: UTF8.self).split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return a.count > 1 ? a : []
    }
}

// MARK: - progress window

@MainActor
final class ProgressWindow: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    init(_ text: String) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 100), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        titlebarAppearsTransparent = true; titleVisibility = .hidden; isMovableByWindowBackground = true
        let bg = NSVisualEffectView(); bg.material = .hudWindow; bg.state = .active; contentView = bg
        spinner.style = .spinning; spinner.controlSize = .regular; spinner.isIndeterminate = true
        label.stringValue = text; label.font = .systemFont(ofSize: 13)
        for v in [spinner, label] { v.translatesAutoresizingMaskIntoConstraints = false; bg.addSubview(v) }
        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 24), spinner.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 14), label.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: bg.trailingAnchor, constant: -20),
        ])
        center(); spinner.startAnimation(nil)
    }
    func update(_ t: String) { label.stringValue = t }
}

// MARK: - welcome

final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?
    private var hot = false { didSet { needsDisplay = true } }
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { hot = true; return .copy }
    override func draggingExited(_ s: NSDraggingInfo?) { hot = false }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        hot = false
        let urls = s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty { return false }
        onDrop?(urls); return true
    }
    override func draw(_ r: NSRect) {
        guard hot else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill(); bounds.fill()
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 14, dy: 14), xRadius: 14, yRadius: 14)
        p.lineWidth = 2; p.setLineDash([8, 6], count: 2, phase: 0); NSColor.controlAccentColor.setStroke(); p.stroke()
    }
}

@MainActor
final class WelcomeController: NSWindowController {
    var onOpen: (() -> Void)?
    var onURLs: (([URL]) -> Void)?
    private let recents = NSStackView()
    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 420), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true; win.titleVisibility = .hidden; win.isMovableByWindowBackground = true
        win.center(); win.setFrameAutosaveName("LanternWelcome")
        super.init(window: win)
        let drop = DropView(frame: win.contentView!.bounds); drop.autoresizingMask = [.width, .height]
        drop.onDrop = { [weak self] in self?.onURLs?($0) }
        win.contentView = drop
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 92).isActive = true; icon.heightAnchor.constraint(equalToConstant: 92).isActive = true
        let title = NSTextField(labelWithString: "Lantern"); title.font = .systemFont(ofSize: 30, weight: .bold)
        let sub = NSTextField(labelWithString: "A native disassembler & decompiler for macOS"); sub.font = .systemFont(ofSize: 13); sub.textColor = .secondaryLabelColor
        let open = NSButton(title: "Open Binary…", target: self, action: #selector(openTapped)); open.bezelStyle = .rounded; open.controlSize = .large; open.keyEquivalent = "\r"
        let hint = NSTextField(labelWithString: "or drop a Mach-O, ELF or PE file, or an .app, here"); hint.font = .systemFont(ofSize: 12); hint.textColor = .tertiaryLabelColor
        let rl = NSTextField(labelWithString: "Recent"); rl.font = .systemFont(ofSize: 11, weight: .semibold); rl.textColor = .secondaryLabelColor
        recents.orientation = .vertical; recents.alignment = .centerX; recents.spacing = 2
        let stack = NSStackView(views: [icon, title, sub, open, hint, rl, recents])
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 8
        stack.setCustomSpacing(2, after: title); stack.setCustomSpacing(18, after: sub); stack.setCustomSpacing(18, after: hint)
        stack.translatesAutoresizingMaskIntoConstraints = false; drop.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: drop.centerXAnchor), stack.centerYAnchor.constraint(equalTo: drop.centerYAnchor, constant: 6)])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    @objc private func openTapped() { onOpen?() }
    @objc private func recentTapped(_ b: NSButton) { if let p = b.toolTip { onURLs?([URL(fileURLWithPath: p)]) } }
    func refresh() {
        recents.arrangedSubviews.forEach { recents.removeArrangedSubview($0); $0.removeFromSuperview() }
        let urls = Array(NSDocumentController.shared.recentDocumentURLs.prefix(5))
        if urls.isEmpty { let l = NSTextField(labelWithString: "Nothing yet"); l.font = .systemFont(ofSize: 12); l.textColor = .tertiaryLabelColor; recents.addArrangedSubview(l) }
        for u in urls {
            let b = NSButton(title: u.lastPathComponent, target: self, action: #selector(recentTapped(_:)))
            b.isBordered = false; b.contentTintColor = .controlAccentColor; b.toolTip = u.path; recents.addArrangedSubview(b)
        }
    }
}

// MARK: - delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var docs: [DocumentWindowController] = []
    private var welcome: WelcomeController?
    private let recentMenu = NSMenu(title: "Open Recent")
    private var launchedWithFiles = false
    private var opening = Set<URL>()

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        if EngineProcess.binaryPath == nil {
            let a = NSAlert(); a.messageText = "Analysis engine missing"
            a.informativeText = "The bundled Erebus engine was not found. Rebuild with scripts/build-app.sh."; a.runModal()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self, !self.launchedWithFiles, self.docs.isEmpty else { return }
            self.showWelcome()
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func application(_ sender: NSApplication, openFiles names: [String]) {
        launchedWithFiles = true
        for n in names { open(URL(fileURLWithPath: n)) }
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows f: Bool) -> Bool { if !f && docs.isEmpty { showWelcome() }; return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ n: Notification) { docs.forEach { $0.engine.stop() } }

    func showWelcome() {
        if welcome == nil {
            let w = WelcomeController()
            w.onOpen = { [weak self] in self?.openPanel() }
            w.onURLs = { [weak self] urls in urls.forEach { self?.open($0) } }
            welcome = w
        }
        welcome?.refresh(); welcome?.showWindow(nil); welcome?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func openPanel() {
        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = true
        p.message = "Choose a binary (Mach-O, ELF, PE) or a Lantern/Erebus database"
        if p.runModal() == .OK { p.urls.forEach { open($0) } }
    }

    func open(_ url: URL, arch preset: String? = nil) {
        if let d = docs.first(where: { $0.source == url }) { d.showWindow(nil); d.window?.makeKeyAndOrderFront(nil); return }
        guard !opening.contains(url) else { return }
        var arch = preset
        let isDB = url.pathExtension.lowercased() == "erdb"
        if !isDB && arch == nil {
            let archs = Paths.fatArchitectures(url)
            if !archs.isEmpty {
                let a = NSAlert(); a.messageText = "\(url.lastPathComponent) contains several architectures"; a.informativeText = "Choose the slice to analyse."
                let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26)); pop.addItems(withTitles: archs); a.accessoryView = pop
                a.addButton(withTitle: "Open"); a.addButton(withTitle: "Cancel")
                if a.runModal() != .alertFirstButtonReturn { return }
                arch = pop.titleOfSelectedItem
            }
        }
        opening.insert(url)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        let progress = ProgressWindow("Analysing \(url.lastPathComponent)…")
        progress.makeKeyAndOrderFront(nil)
        welcome?.close()
        let db = isDB ? url : Paths.database(for: url, arch: arch)
        let sliceArch = arch
        Task {
            defer { self.opening.remove(url); progress.orderOut(nil) }
            if !isDB && !FileManager.default.fileExists(atPath: db.path) {
                let r = await Task.detached { () -> (Int32, String) in
                    var args = ["open", url.path, "-o", db.path, "-q"]; if let a = sliceArch { args += ["--arch", a] }
                    let r = EngineProcess.run(args); return (r.status, r.err)
                }.value
                if r.0 != 0 { self.alert("Couldn't open \(url.lastPathComponent)", r.1.isEmpty ? "Analysis failed." : r.1); self.showWelcomeIfIdle(); return }
            }
            progress.update("Starting…")
            let engine = EngineProcess()
            let started: Result<URL, EngineError> = await withCheckedContinuation { c in engine.start(database: db) { c.resume(returning: $0) } }
            switch started {
            case .failure(let e): self.alert("Couldn't start the engine", e.localizedDescription); self.showWelcomeIfIdle()
            case .success(let base):
                let dc = DocumentWindowController(source: url, database: db, engine: engine, api: EngineAPI(base: base))
                dc.onClose = { [weak self] c in self?.docs.removeAll { $0 === c } }
                self.docs.append(dc)
                dc.showWindow(nil); dc.window?.center(); dc.window?.makeKeyAndOrderFront(nil)
                await dc.load()
            }
        }
    }
    private func showWelcomeIfIdle() { if docs.isEmpty { showWelcome() } }
    private func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.alertStyle = .warning; a.messageText = title; a.informativeText = String(text.prefix(600)); a.runModal()
    }

    private var front: DocumentWindowController? { docs.first { $0.window === NSApp.keyWindow } ?? docs.last }
    @objc func openGitHub() { NSWorkspace.shared.open(URL(string: "https://github.com/blazfxx/lantern")!) }
    @objc func reportIssue() { NSWorkspace.shared.open(URL(string: "https://github.com/blazfxx/lantern/issues/new/choose")!) }
    @objc func openRecent(_ i: NSMenuItem) { if let u = i.representedObject as? URL { open(u) } }
    @objc func clearRecents() { NSDocumentController.shared.clearRecentDocuments(nil); welcome?.refresh() }
    @objc func showAbout() {
        let c = NSAttributedString(string: "A native disassembler & decompiler for macOS.\nMIT License · github.com/blazfxx/lantern\nEngine \(EngineProcess.version)",
                                   attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: c, .applicationName: "Lantern"])
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        for u in urls.prefix(10) { let it = NSMenuItem(title: u.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: ""); it.representedObject = u; it.target = self; menu.addItem(it) }
        if !urls.isEmpty { menu.addItem(.separator()) }
        let c = NSMenuItem(title: "Clear Menu", action: #selector(clearRecents), keyEquivalent: ""); c.target = self; menu.addItem(c)
    }

    // MARK: menus (actions with nil target travel the responder chain to the key window's controller)

    private func buildMenu() {
        let main = NSMenu()
        func sub(_ t: String) -> NSMenu { let m = NSMenu(title: t); let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.submenu = m; main.addItem(i); return m }
        func add(_ t: String, _ m: NSMenu, _ a: Selector?, _ k: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k); i.keyEquivalentModifierMask = mods; i.target = target; m.addItem(i)
        }
        let app = sub("Lantern")
        add("About Lantern", app, #selector(showAbout), target: self); app.addItem(.separator())
        add("Hide Lantern", app, #selector(NSApplication.hide(_:)), "h")
        add("Hide Others", app, #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]); app.addItem(.separator())
        add("Quit Lantern", app, #selector(NSApplication.terminate(_:)), "q")

        let file = sub("File")
        add("Open…", file, #selector(openPanel), "o", target: self)
        let ri = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: ""); recentMenu.delegate = self; ri.submenu = recentMenu; file.addItem(ri)
        file.addItem(.separator())
        add("Export Patched Binary…", file, #selector(DocumentWindowController.exportAction(_:)), "e", [.command, .shift])
        add("Re-analyse", file, #selector(DocumentWindowController.reanalyzeAction(_:)), "r", [.command, .shift])
        add("Reveal Database in Finder", file, #selector(DocumentWindowController.revealDatabase(_:)))
        file.addItem(.separator()); add("Close Window", file, #selector(NSWindow.performClose(_:)), "w")

        let edit = sub("Edit")
        add("Copy", edit, #selector(NSText.copy(_:)), "c"); add("Select All", edit, #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator()); add("Copy Pseudo-code", edit, #selector(DocumentWindowController.copyPseudo(_:)), "c", [.command, .shift])

        let nav = sub("Navigate")
        add("Back", nav, #selector(DocumentWindowController.goBackAction(_:)), "[")
        add("Forward", nav, #selector(DocumentWindowController.goForwardAction(_:)), "]")
        nav.addItem(.separator())
        add("Go to…  (G)", nav, #selector(DocumentWindowController.gotoAction(_:)), "l")
        add("Command Palette…", nav, #selector(DocumentWindowController.showPalette(_:)), "p", [.command, .shift])
        add("Filter Sidebar", nav, #selector(DocumentWindowController.focusFilter(_:)), "f")

        let view = sub("View")
        add("Assembly", view, #selector(DocumentWindowController.showAssembly(_:)), "1")
        add("Control-Flow Graph", view, #selector(DocumentWindowController.showGraphMode(_:)), "2")
        add("Pseudo-code", view, #selector(DocumentWindowController.showPseudoMode(_:)), "3")
        add("Hex", view, #selector(DocumentWindowController.showHexMode(_:)), "4")
        add("Fit Graph to Window  (F)", view, #selector(DocumentWindowController.fitGraph(_:)), "0", [.command, .option])
        view.addItem(.separator()); add("Show Opcode Bytes  (B)", view, #selector(DocumentWindowController.toggleBytes(_:)), "b", [.command, .option])
        view.addItem(.separator()); add("Enter Full Screen", view, #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        let an = sub("Analysis")
        add("Rename…  (N)", an, #selector(DocumentWindowController.renameAction(_:)))
        add("Add Comment…  (;)", an, #selector(DocumentWindowController.commentAction(_:)))
        an.addItem(.separator())
        add("Assemble Instruction…  (A)", an, #selector(DocumentWindowController.assembleAction(_:)))
        add("Patch Bytes…  (P)", an, #selector(DocumentWindowController.patchAction(_:)))
        add("Revert Patch  (U)", an, #selector(DocumentWindowController.revertAction(_:)))

        let win = sub("Window")
        add("Minimize", win, #selector(NSWindow.performMiniaturize(_:)), "m"); add("Zoom", win, #selector(NSWindow.performZoom(_:)))
        NSApp.windowsMenu = win
        let help = sub("Help")
        add("Lantern on GitHub", help, #selector(openGitHub), target: self); add("Report an Issue…", help, #selector(reportIssue), target: self)
        NSApp.helpMenu = help
        NSApp.mainMenu = main
    }
}
