#!/usr/bin/env bash
# Renders the instructional DMG window background (Resources/dmg-background@2x.png):
# a calm light canvas with "Drag Aloud into Applications" and an arrow between
# the two icon positions create-dmg lays out (app at 170,210 / link at 490,210
# in a 660x420 window).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/bg.swift" <<'SWIFT'
import AppKit

let w: CGFloat = 660, h: CGFloat = 420, scale: CGFloat = 2
let size = NSSize(width: w * scale, height: h * scale)
let image = NSImage(size: size)
image.lockFocus()
NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)

// Soft neutral backdrop, slightly warm so it reads in light and dark Finder.
NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: w, height: h).fill()

// Title
let title = "Drag Aloud into Applications"
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
    .foregroundColor: NSColor(calibratedWhite: 0.25, alpha: 1),
]
let titleSize = title.size(withAttributes: titleAttrs)
title.draw(at: NSPoint(x: (w - titleSize.width) / 2, y: h - 64), withAttributes: titleAttrs)

// Subtitle
let sub = "Then open it from Applications — that’s the whole install."
let subAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 12, weight: .regular),
    .foregroundColor: NSColor(calibratedWhite: 0.55, alpha: 1),
]
let subSize = sub.size(withAttributes: subAttrs)
sub.draw(at: NSPoint(x: (w - subSize.width) / 2, y: h - 86), withAttributes: subAttrs)

// Arrow between icon slots. Icons sit at y≈210 from top → 420-210=210 from
// bottom in Quartz coords; icons are 128pt, so the arrow runs between x≈250
// and x≈410 at the icon centerline.
let arrowY: CGFloat = h - 210
let path = NSBezierPath()
path.move(to: NSPoint(x: 262, y: arrowY))
path.line(to: NSPoint(x: 390, y: arrowY))
path.lineWidth = 4
path.lineCapStyle = .round
NSColor(calibratedWhite: 0.72, alpha: 1).setStroke()
path.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 376, y: arrowY + 10))
head.line(to: NSPoint(x: 394, y: arrowY))
head.line(to: NSPoint(x: 376, y: arrowY - 10))
head.lineWidth = 4
head.lineCapStyle = .round
head.lineJoinStyle = .round
NSColor(calibratedWhite: 0.72, alpha: 1).setStroke()
head.stroke()

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
rep.size = NSSize(width: w, height: h)   // 2x DPI
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT

swift "$TMP/bg.swift" Resources/dmg-background@2x.png
echo "==> Wrote Resources/dmg-background@2x.png"
