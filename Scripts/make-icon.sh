#!/usr/bin/env bash
#
# make-icon.sh — generate the app icon (App/AppIcon.icns).
#
# The mark: a temple doorway (arch on steps) with a terminal prompt lit inside.
# Deliberately not a colonnade — columns read as a bank at any size.
#
# Each size is drawn directly with CoreGraphics rather than downscaled from one
# master, so the small variants stay crisp. iconutil packs the .iconset.
#
# Idempotent: safe to re-run; overwrites App/AppIcon.icns.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_ICNS="$ROOT/App/AppIcon.icns"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
SWIFT_SRC="$WORK/draw.swift"

cat > "$SWIFT_SRC" <<'SWIFT'
import AppKit

/// Temple's mark: a doorway (arch + steps) with a terminal prompt inside.
func drawIcon(size S: CGFloat, into ctx: CGContext) {
    let r = NSRect(x: 0, y: 0, width: S, height: S)
    let u = S / 512   // everything below is in 512-unit design space

    let cream = NSColor(calibratedRed: 0.98, green: 0.965, blue: 0.94, alpha: 1)
    let terraTop = NSColor(calibratedRed: 0.88, green: 0.58, blue: 0.44, alpha: 1)
    let terraBot = NSColor(calibratedRed: 0.74, green: 0.42, blue: 0.31, alpha: 1)
    let inkTop = NSColor(calibratedRed: 0.18, green: 0.18, blue: 0.20, alpha: 1)
    let inkBot = NSColor(calibratedRed: 0.085, green: 0.085, blue: 0.095, alpha: 1)
    let terra = NSGradient(starting: terraTop, ending: terraBot)!

    ctx.saveGState()
    NSBezierPath(roundedRect: r, xRadius: S * 0.2237, yRadius: S * 0.2237).addClip()
    NSGradient(starting: inkTop, ending: inkBot)!.draw(in: r, angle: -90)

    func archPath(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: x, y: y))
        p.line(to: NSPoint(x: x, y: y + h - w / 2))
        p.appendArc(withCenter: NSPoint(x: x + w / 2, y: y + h - w / 2), radius: w / 2,
                    startAngle: 180, endAngle: 0, clockwise: true)
        p.line(to: NSPoint(x: x + w, y: y))
        p.close()
        return p
    }

    let w = 250 * u, h = 250 * u
    let x = (S - w) / 2, y = 150 * u
    terra.draw(in: archPath(x, y, w, h), angle: -90)

    let jamb = 30 * u                                   // wall thickness
    NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.08, alpha: 1).setFill()
    archPath(x + jamb, y, w - 2 * jamb, h - jamb).fill()

    let cx = S / 2 - 12 * u, cy = y + 92 * u            // prompt, optically centered
    let caret = NSBezierPath()
    caret.move(to: NSPoint(x: cx - 30 * u, y: cy + 30 * u))
    caret.line(to: NSPoint(x: cx + 12 * u, y: cy))
    caret.line(to: NSPoint(x: cx - 30 * u, y: cy - 30 * u))
    caret.lineWidth = 21 * u
    caret.lineCapStyle = .round
    caret.lineJoinStyle = .round
    cream.setStroke()
    caret.stroke()
    cream.setFill()
    NSBezierPath(roundedRect: NSRect(x: cx + 30 * u, y: cy - 40 * u, width: 46 * u, height: 17 * u),
                 xRadius: 8.5 * u, yRadius: 8.5 * u).fill()

    for (inset, base) in [(22 * u, 118 * u), (46 * u, 88 * u)] {   // steps
        terra.draw(in: NSBezierPath(
            roundedRect: NSRect(x: x - inset, y: base, width: w + 2 * inset, height: 24 * u),
            xRadius: 5 * u, yRadius: 5 * u), angle: -90)
    }
    ctx.restoreGState()
}

let out = CommandLine.arguments[1]
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                    (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = CGFloat(pt * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(size: px, into: NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}
SWIFT

echo "==> drawing iconset"
swift "$SWIFT_SRC" "$ICONSET"

echo "==> packing $OUT_ICNS"
mkdir -p "$ROOT/App"
iconutil -c icns "$ICONSET" -o "$OUT_ICNS"
echo "==> done: $OUT_ICNS"
