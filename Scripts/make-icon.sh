#!/usr/bin/env bash
#
# make-icon.sh — generate a minimal placeholder app icon (App/AppIcon.icns).
#
# Draws a rounded-rect terracotta tile with a white "T" via CoreGraphics, then
# builds a full .iconset (16pt→512pt @1x/@2x) and packs it with iconutil.
# Tasteful, deliberately simple — replace App/AppIcon.icns with a real icon
# later and this script becomes a no-op you can delete.
#
# Idempotent: safe to re-run; overwrites App/AppIcon.icns.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_ICNS="$ROOT/App/AppIcon.icns"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BASE_PNG="$WORK/icon_1024.png"
SWIFT_SRC="$WORK/draw.swift"

cat > "$SWIFT_SRC" <<'SWIFT'
import AppKit

let px = 1024
let out = CommandLine.arguments[1]

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("rep") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let size = CGFloat(px)
let full = CGRect(x: 0, y: 0, width: size, height: size)
// macOS icon grid: content inset ~ 10%, corner radius ~ 22% of the tile.
let tile = full.insetBy(dx: size * 0.085, dy: size * 0.085)
let radius = tile.width * 0.235
let path = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

// Brand terracotta → deeper terracotta diagonal gradient.
let top = NSColor(calibratedRed: 0.87, green: 0.49, blue: 0.36, alpha: 1.0)      // #DE7D5C-ish
let bottom = NSColor(calibratedRed: 0.74, green: 0.35, blue: 0.24, alpha: 1.0)   // deeper
path.addClip()
NSGradient(starting: top, ending: bottom)!.draw(in: tile, angle: -90)
NSGraphicsContext.current?.cgContext.resetClip()

// White "T".
let glyph = "T"
let font = NSFont.systemFont(ofSize: size * 0.62, weight: .bold)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.white,
]
let s = NSAttributedString(string: glyph, attributes: attrs)
let bounds = s.size()
let origin = NSPoint(x: (size - bounds.width) / 2, y: (size - bounds.height) / 2)
s.draw(at: origin)

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try! data.write(to: URL(fileURLWithPath: out))
SWIFT

echo "==> drawing base 1024×1024 icon"
swift "$SWIFT_SRC" "$BASE_PNG"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

# name:size pairs for the standard macOS iconset
declare -a specs=(
  "icon_16x16.png:16"
  "icon_16x16@2x.png:32"
  "icon_32x32.png:32"
  "icon_32x32@2x.png:64"
  "icon_128x128.png:128"
  "icon_128x128@2x.png:256"
  "icon_256x256.png:256"
  "icon_256x256@2x.png:512"
  "icon_512x512.png:512"
  "icon_512x512@2x.png:1024"
)

echo "==> resizing iconset variants"
for spec in "${specs[@]}"; do
  name="${spec%%:*}"
  dim="${spec##*:}"
  sips -z "$dim" "$dim" "$BASE_PNG" --out "$ICONSET/$name" >/dev/null
done

echo "==> packing $OUT_ICNS"
mkdir -p "$ROOT/App"
iconutil -c icns "$ICONSET" -o "$OUT_ICNS"
echo "==> done: $OUT_ICNS"
