// A read-only, no-wrap text view for listings: clickable symbols, line selection/highlight, vim-ish hotkeys.
import AppKit

final class CodeTextView: NSTextView {
    var onRef: ((String) -> Void)?
    var onLine: ((String) -> Void)?
    var onHover: ((String?) -> Void)?
    var onKey: ((String) -> Bool)?
    private(set) var hoverRef: String?
    private(set) var rendered: RenderedText?
    private var highlighted: NSRange?

    override init(frame: NSRect, textContainer: NSTextContainer?) { super.init(frame: frame, textContainer: textContainer); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        isEditable = false; isSelectable = true; isRichText = true
        usesFontPanel = false; allowsUndo = false
        isAutomaticLinkDetectionEnabled = false; isAutomaticQuoteSubstitutionEnabled = false
        drawsBackground = true; backgroundColor = .textBackgroundColor
        textContainerInset = NSSize(width: 10, height: 8)
        isHorizontallyResizable = true; isVerticallyResizable = true
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = false
        textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        font = Theme.font
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil))
    }

    func show(_ r: RenderedText) {
        rendered = r; highlighted = nil
        textStorage?.setAttributedString(r.text)
        setSelectedRange(NSRange(location: 0, length: 0))
    }

    /// Highlights the line of `addr` and scrolls it to the middle of the view.
    func reveal(_ addr: String, center: Bool = true) {
        guard let lm = layoutManager, let tc = textContainer, let r = rendered?.lineRanges[addr] else { return }
        if let old = highlighted { lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: old) }
        lm.addTemporaryAttribute(.backgroundColor, value: Theme.select, forCharacterRange: r)
        highlighted = r
        guard center else { return }
        let g = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: g, in: tc)
        rect.origin.y += textContainerInset.height
        if let sv = enclosingScrollView {
            let vis = sv.contentView.bounds
            let y = max(0, rect.midY - vis.height / 2)
            sv.contentView.scroll(to: NSPoint(x: vis.origin.x, y: y))
            sv.reflectScrolledClipView(sv.contentView)
        }
    }

    private func attrs(at event: NSEvent) -> (idx: Int, attrs: [NSAttributedString.Key: Any])? {
        let p = convert(event.locationInWindow, from: nil)
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage, ts.length > 0 else { return nil }
        var q = p; q.x -= textContainerInset.width; q.y -= textContainerInset.height
        let g = lm.glyphIndex(for: q, in: tc, fractionOfDistanceThroughGlyph: nil)
        let bounds = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
        guard bounds.contains(q) else { return nil }
        let idx = lm.characterIndexForGlyph(at: g)
        guard idx < ts.length else { return nil }
        return (idx, ts.attributes(at: idx, effectiveRange: nil))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let a = attrs(at: event) {
            if let ref = a.attrs[.ref] as? String { onRef?(ref); return }
            if let line = a.attrs[.line] as? String { onLine?(line) }
        }
        super.mouseDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        let ref = attrs(at: event)?.attrs[.ref] as? String
        if ref != hoverRef { hoverRef = ref; onHover?(ref) }
        (ref != nil ? NSCursor.pointingHand : NSCursor.iBeam).set()
    }
    override func mouseExited(with event: NSEvent) { if hoverRef != nil { hoverRef = nil; onHover?(nil) } }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if mods.isEmpty, let c = event.characters, c.count == 1, onKey?(c) == true { return }
        super.keyDown(with: event)
    }
}

enum CodeView {
    /// (scroll view, text view) pair configured for listings.
    static func make() -> (NSScrollView, CodeTextView) {
        // TextKit 1 stack, assembled bottom-up: storage -> layout manager -> container -> view
        let storage = NSTextStorage()
        let lm = NSLayoutManager(); storage.addLayoutManager(lm)
        let container = NSTextContainer(containerSize: NSSize(width: 1e7, height: 1e7))
        container.widthTracksTextView = false
        lm.addTextContainer(container)
        let tv = CodeTextView(frame: .zero, textContainer: container)
        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true; sv.hasHorizontalScroller = true; sv.autohidesScrollers = true
        sv.drawsBackground = true; sv.backgroundColor = .textBackgroundColor
        return (sv, tv)
    }
}
