#!/usr/bin/env swift
//
// Draws the background image for SFTPsurf's disk image.
//
// Run with:  swift Scripts/make-dmg-background.swift <output.png>
//
// The layout mirrors what Scripts/make-dmg.sh tells Finder to do: the app on the
// left, an arrow, the Applications alias on the right. Keeping the two in step
// matters, because a background that does not line up with the icons looks
// broken. `make-dmg.sh` prints the icon positions it uses for exactly that
// reason.

import AppKit
import Foundation

// Logical size, in points, of the window Finder will show. Drawn at 2x so it
// stays sharp on a Retina display.
let width: CGFloat = 700
let height: CGFloat = 440
let scale: CGFloat = 2

// Where Finder places the two icons, in points from the content area's top-left.
// make-dmg.sh passes these same numbers to AppleScript.
let appIconCenter = CGPoint(x: 175, y: 205)
let applicationsIconCenter = CGPoint(x: 525, y: 205)

/// Converts a distance from the top edge into Quartz's bottom-left origin.
private func fromTop(_ distance: CGFloat) -> CGFloat { height - distance }

/// A rect measured from the top-left, as the icon positions are.
private func rectFromTop(_ top: CGFloat, _ left: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: left, y: fromTop(top + h), width: w, height: h)
}

private func drawBackground() {
    // A soft vertical wash rather than flat white, so it reads as a designed
    // surface rather than an accident. Angle 90 lights it from the top.
    NSGradient(colors: [
        NSColor(srgbRed: 0.92, green: 0.95, blue: 0.99, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.99, blue: 1.00, alpha: 1),
    ])?.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 90)

    let centered = NSMutableParagraphStyle()
    centered.alignment = .center

    let title = NSAttributedString(string: "SFTPsurf", attributes: [
        .font: NSFont.systemFont(ofSize: 40, weight: .semibold),
        .foregroundColor: NSColor(srgbRed: 0.10, green: 0.16, blue: 0.26, alpha: 1),
        .paragraphStyle: centered,
    ])
    title.draw(in: rectFromTop(42, 0, width, 50))

    let subtitle = NSAttributedString(string: "SFTP and FTP browser for macOS", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .regular),
        .foregroundColor: NSColor(srgbRed: 0.36, green: 0.43, blue: 0.53, alpha: 1),
        .paragraphStyle: centered,
    ])
    subtitle.draw(in: rectFromTop(88, 0, width, 22))

    drawArrow(
        from: CGPoint(x: appIconCenter.x + 64, y: fromTop(appIconCenter.y)),
        to: CGPoint(x: applicationsIconCenter.x - 64, y: fromTop(applicationsIconCenter.y))
    )

    // A quiet nudge for anyone who does not know what to do with a disk image.
    let hint = NSAttributedString(string: "Drag SFTPsurf onto Applications to install", attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 0.44, green: 0.51, blue: 0.61, alpha: 1),
        .paragraphStyle: centered,
    ])
    hint.draw(in: rectFromTop(height - 56, 0, width, 20))
}

/// A thin line with a chevron head.
///
/// Deliberately understated: a heavy filled arrow competes with the two icons it
/// sits between. A slim rule in a muted slate reads as wayfinding rather than
/// decoration, and the open chevron keeps it from looking blunt.
private func drawArrow(from start: CGPoint, to end: CGPoint) {
    let tint = NSColor(srgbRed: 0.44, green: 0.54, blue: 0.68, alpha: 1)
    let lineWidth: CGFloat = 2.5
    let headLength: CGFloat = 19
    let headHalfWidth: CGFloat = 11

    tint.setStroke()

    // Stop the shaft just short of the tip so the join stays crisp.
    let shaft = NSBezierPath()
    shaft.move(to: start)
    shaft.line(to: CGPoint(x: end.x - lineWidth, y: end.y))
    shaft.lineWidth = lineWidth
    shaft.lineCapStyle = .round
    shaft.stroke()

    let head = NSBezierPath()
    head.move(to: CGPoint(x: end.x - headLength, y: end.y - headHalfWidth))
    head.line(to: end)
    head.line(to: CGPoint(x: end.x - headLength, y: end.y + headHalfWidth))
    head.lineWidth = lineWidth
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()
}

/// Renders the background and returns PNG data.
private func render() -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(width * scale),
        pixelsHigh: Int(height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    rep.size = NSSize(width: width, height: height)
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    // Drawn in Quartz's usual bottom-left space. AppKit text drawing ignores a
    // flipped transform's orientation and would come out mirrored, so the
    // top-left coordinates above are converted by `fromTop` instead.
    drawBackground()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

// MARK: - Write

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "build/dmg-background.png"

guard let png = render() else {
    FileHandle.standardError.write(Data("could not render the background\n".utf8))
    exit(1)
}

let url = URL(fileURLWithPath: outputPath)
do {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try png.write(to: url)
    print("Wrote \(url.path) (\(png.count / 1024) KB, \(Int(width))x\(Int(height)) @\(Int(scale))x)")
} catch {
    FileHandle.standardError.write(Data("could not write \(outputPath): \(error)\n".utf8))
    exit(1)
}
