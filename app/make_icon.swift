// Generates the Lantern app icon (an .iconset) with CoreGraphics — no binary assets in the repo.
// usage: swift app/make_icon.swift <out.iconset>
import Cocoa

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let inset = s * 0.1
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.2237, cornerHeight: rect.width * 0.2237, transform: nil)
    func C(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor { CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a) }

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(path); ctx.setFillColor(C(10, 14, 28)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [C(8, 12, 26), C(24, 40, 70)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])

    // warm glow behind the lantern
    let cx = rect.midX, cy = rect.minY + rect.height * 0.50
    let glow = CGGradient(colorsSpace: cs, colors: [C(255, 176, 64, 0.55), C(255, 140, 40, 0.18), C(255, 120, 30, 0)] as CFArray, locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: cx, y: cy), startRadius: 0, endCenter: CGPoint(x: cx, y: cy), endRadius: rect.width * 0.55, options: [])

    // faint "listing" lines in the dark, lit by the lantern
    for i in 0..<7 {
        let y = rect.minY + rect.height * (0.14 + CGFloat(i) * 0.115)
        let len = rect.width * (0.28 + 0.34 * CGFloat((i * 37 % 10)) / 10)
        let x = rect.minX + rect.width * 0.10 + (i % 2 == 0 ? 0 : rect.width * 0.06)
        let r = CGRect(x: x, y: y, width: len, height: rect.height * 0.018)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil))
        ctx.setFillColor(C(120, 160, 220, 0.12)); ctx.fillPath()
    }

    // lantern: handle, cap, glass body, cage bars, base
    let bw = rect.width * 0.30, bh = rect.height * 0.34
    let body = CGRect(x: cx - bw / 2, y: cy - bh / 2 - rect.height * 0.02, width: bw, height: bh)
    ctx.setStrokeColor(C(30, 36, 52)); ctx.setLineWidth(rect.width * 0.022); ctx.setLineCap(.round)
    ctx.addArc(center: CGPoint(x: cx, y: body.maxY + rect.height * 0.045), radius: bw * 0.30, startAngle: 0, endAngle: .pi, clockwise: false)
    ctx.strokePath()
    let capH = rect.height * 0.055
    let cap = CGMutablePath()
    cap.move(to: CGPoint(x: body.minX - bw * 0.06, y: body.maxY))
    cap.addLine(to: CGPoint(x: body.maxX + bw * 0.06, y: body.maxY))
    cap.addLine(to: CGPoint(x: body.maxX - bw * 0.10, y: body.maxY + capH))
    cap.addLine(to: CGPoint(x: body.minX + bw * 0.10, y: body.maxY + capH)); cap.closeSubpath()
    ctx.addPath(cap); ctx.setFillColor(C(34, 40, 58)); ctx.fillPath()

    let glass = CGPath(roundedRect: body, cornerWidth: bw * 0.22, cornerHeight: bw * 0.22, transform: nil)
    ctx.saveGState(); ctx.addPath(glass); ctx.clip()
    let flame = CGGradient(colorsSpace: cs, colors: [C(255, 238, 170), C(255, 196, 84), C(255, 140, 48)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawRadialGradient(flame, startCenter: CGPoint(x: body.midX, y: body.midY), startRadius: 0, endCenter: CGPoint(x: body.midX, y: body.midY), endRadius: bh * 0.75, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
    // cage bars
    ctx.setStrokeColor(C(30, 36, 52)); ctx.setLineWidth(rect.width * 0.016)
    for k in [-1, 0, 1] {
        let x = body.midX + CGFloat(k) * bw * 0.27
        ctx.move(to: CGPoint(x: x, y: body.minY)); ctx.addLine(to: CGPoint(x: x, y: body.maxY)); ctx.strokePath()
    }
    ctx.addPath(glass); ctx.setLineWidth(rect.width * 0.02); ctx.strokePath()
    let base = CGRect(x: body.minX - bw * 0.04, y: body.minY - rect.height * 0.035, width: bw * 1.08, height: rect.height * 0.045)
    ctx.addPath(CGPath(roundedRect: base, cornerWidth: base.height / 2, cornerHeight: base.height / 2, transform: nil))
    ctx.setFillColor(C(34, 40, 58)); ctx.fillPath()
    ctx.restoreGState()

    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count > 1 else { print("usage: make_icon.swift <out.iconset>"); exit(1) }
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(size: base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(size: base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
