#!/usr/bin/env bash
#
# make-icon.sh — generate the app icon (App/AppIcon.icns).
#
# The mark: a temple gate — pediment over two pillars, with a terminal prompt lit
# in the doorway. Angular on purpose: a rounded arch reads as a headstone, and a
# full colonnade reads as a bank.
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

/// Temple's mark: a gate (pediment + two pillars) with a terminal prompt inside.
func drawIcon(size S: CGFloat, into ctx: CGContext) {
    let r = NSRect(x: 0, y: 0, width: S, height: S)
    let u = S / 512   // everything below is in 512-unit design space

    let cream = NSColor(calibratedRed: 0.98, green: 0.965, blue: 0.94, alpha: 1)
    let terra = NSGradient(
        starting: NSColor(calibratedRed: 0.88, green: 0.58, blue: 0.44, alpha: 1),
        ending: NSColor(calibratedRed: 0.74, green: 0.42, blue: 0.31, alpha: 1))!
    let inkTop = NSColor(calibratedRed: 0.18, green: 0.18, blue: 0.20, alpha: 1)
    let inkBot = NSColor(calibratedRed: 0.085, green: 0.085, blue: 0.095, alpha: 1)

    ctx.saveGState()
    NSBezierPath(roundedRect: r, xRadius: S * 0.2237, yRadius: S * 0.2237).addClip()
    NSGradient(starting: inkTop, ending: inkBot)!.draw(in: r, angle: -90)

    let cx = S / 2

    let pediment = NSBezierPath()                       // gable roof
    pediment.move(to: NSPoint(x: cx - 165 * u, y: 330 * u))
    pediment.line(to: NSPoint(x: cx, y: 430 * u))
    pediment.line(to: NSPoint(x: cx + 165 * u, y: 330 * u))
    pediment.close()
    terra.draw(in: pediment, angle: -90)

    terra.draw(in: NSBezierPath(                        // architrave
        roundedRect: NSRect(x: cx - 150 * u, y: 296 * u, width: 300 * u, height: 30 * u),
        xRadius: 4 * u, yRadius: 4 * u), angle: -90)

    for x in [cx - 140 * u, cx + 94 * u] {              // two pillars = a doorway
        terra.draw(in: NSBezierPath(
            rect: NSRect(x: x, y: 130 * u, width: 46 * u, height: 162 * u)), angle: -90)
    }

    terra.draw(in: NSBezierPath(                        // step
        roundedRect: NSRect(x: cx - 168 * u, y: 100 * u, width: 336 * u, height: 26 * u),
        xRadius: 4 * u, yRadius: 4 * u), angle: -90)

    let px = cx - 8 * u, py = 208 * u                   // prompt, lit in the doorway
    let caret = NSBezierPath()
    caret.move(to: NSPoint(x: px - 28 * u, y: py + 28 * u))
    caret.line(to: NSPoint(x: px + 10 * u, y: py))
    caret.line(to: NSPoint(x: px - 28 * u, y: py - 28 * u))
    caret.lineWidth = 20 * u
    caret.lineCapStyle = .round
    caret.lineJoinStyle = .round
    cream.setStroke()
    caret.stroke()
    cream.setFill()
    NSBezierPath(roundedRect: NSRect(x: px + 26 * u, y: py - 38 * u, width: 44 * u, height: 16 * u),
                 xRadius: 8 * u, yRadius: 8 * u).fill()
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
