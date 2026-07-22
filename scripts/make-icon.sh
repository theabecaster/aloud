#!/usr/bin/env bash
# Generates Resources/AppIcon.icns: a macOS-style rounded-square gradient tile
# with a white waveform glyph (SF Symbol), rendered by a small Swift program.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/icon.swift" <<'SWIFT'
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// Transparent canvas; macOS icon grid: tile is ~824pt of the 1024 canvas.
let inset = size * 0.098
let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius = tile.width * 0.225
let path = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

// Modern macOS system-blue gradient (azure → deep blue, #0A84FF family).
let top = NSColor(calibratedRed: 0.22, green: 0.60, blue: 1.00, alpha: 1)
let bottom = NSColor(calibratedRed: 0.00, green: 0.32, blue: 0.85, alpha: 1)
NSGradient(starting: top, ending: bottom)!.draw(in: path, angle: -90)

// Waveform glyph, white, centered.
let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .medium)
if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1.0)
    NSColor.white.set()
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    let glyphSize = NSSize(width: tile.width * 0.62,
                           height: tile.width * 0.62 * (symbol.size.height / symbol.size.width))
    let origin = NSPoint(x: tile.midX - glyphSize.width / 2,
                         y: tile.midY - glyphSize.height / 2)
    tinted.draw(in: NSRect(origin: origin, size: glyphSize))
}

image.unlockFocus()

let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
rep.size = NSSize(width: size, height: size)
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT

swift "$TMP/icon.swift" "$TMP/icon-1024.png"

ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$TMP/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done

mkdir -p Resources
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "==> Wrote Resources/AppIcon.icns"
