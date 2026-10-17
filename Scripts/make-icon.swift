#!/usr/bin/env swift
//
// Draws SFTPsurf's app icon and packs it into Resources/AppIcon.icns.
//
// Run with:  swift Scripts/make-icon.swift
//
// Doing this in code keeps the icon reproducible and avoids shipping a binary
// blob nobody can edit.

import AppKit
import Foundation

let packageRoot = URL(fileURLWithPath: CommandLine.arguments.first ?? ".")
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let resources = packageRoot.appendingPathComponent("Resources", isDirectory: true)
let iconset = packageRoot.appendingPathComponent("build/AppIcon.iconset", isDirectory: true)

/// macOS draws app icons inside a rounded rectangle that occupies about 82% of
/// the canvas, with a corner radius near 22.4% of that rectangle's width.
private func drawIcon(size: CGFloat) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    context.clear(canvas)

    let inset = size * 0.09
    let body = canvas.insetBy(dx: inset, dy: inset)
    let radius = body.width * 0.2237

    let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Drop shadow so the icon sits on a light or dark desktop.
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -size * 0.012),
        blur: size * 0.03,
        color: NSColor.black.withAlphaComponent(0.28).cgColor
    )
    context.addPath(shape)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()

    // Ocean gradient: the "surf" half of the name.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let colors = [
        NSColor(srgbRed: 0.13, green: 0.45, blue: 0.93, alpha: 1).cgColor,
        NSColor(srgbRed: 0.06, green: 0.72, blue: 0.79, alpha: 1).cgColor,
    ] as CFArray
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: body.minX, y: body.maxY),
            end: CGPoint(x: body.maxX, y: body.minY),
            options: []
        )
    }

    // Soft highlight across the top third.
    if let gloss = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor.white.withAlphaComponent(0.30).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor,
        ] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gloss,
            start: CGPoint(x: body.midX, y: body.maxY),
            end: CGPoint(x: body.midX, y: body.midY),
            options: []
        )
    }
    context.restoreGState()

    // Two arrows: up on the left, down on the right — the transfer idea.
    let stroke = size * 0.072
    let offset = size * 0.115
    let centre = CGPoint(x: body.midX, y: body.midY)
    let shaftHalf = size * 0.20
    let headHalf = size * 0.105

    context.setStrokeColor(NSColor.white.cgColor)
    context.setLineWidth(stroke)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    func drawArrow(atX x: CGFloat, pointingUp: Bool) {
        let top = pointingUp ? centre.y + shaftHalf : centre.y + shaftHalf
        let bottom = pointingUp ? centre.y - shaftHalf : centre.y - shaftHalf
        let tip = pointingUp ? top : bottom
        let tail = pointingUp ? bottom : top

        context.move(to: CGPoint(x: x, y: tail))
        context.addLine(to: CGPoint(x: x, y: tip))

        // Arrowhead points away from the tail.
        let wingY = pointingUp ? tip - headHalf : tip + headHalf
        context.move(to: CGPoint(x: x - headHalf, y: wingY))
        context.addLine(to: CGPoint(x: x, y: tip))
        context.addLine(to: CGPoint(x: x + headHalf, y: wingY))
        context.strokePath()
    }

    drawArrow(atX: centre.x - offset, pointingUp: true)
    drawArrow(atX: centre.x + offset, pointingUp: false)
}

private func renderPNG(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    rep.size = NSSize(width: pixels, height: pixels)
    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    drawIcon(size: CGFloat(pixels))
    graphicsContext.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

// MARK: - Build the iconset

let fileManager = FileManager.default
try? fileManager.removeItem(at: iconset)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

// (point size, scale) pairs that iconutil expects.
let variants: [(point: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

for variant in variants {
    let pixels = variant.point * variant.scale
    guard let data = renderPNG(pixels: pixels) else {
        FileHandle.standardError.write(Data("failed to render \(pixels)px\n".utf8))
        exit(1)
    }
    let name = variant.scale == 1
        ? "icon_\(variant.point)x\(variant.point).png"
        : "icon_\(variant.point)x\(variant.point)@2x.png"
    try data.write(to: iconset.appendingPathComponent(name))
}

try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = [
    "-c", "icns",
    iconset.path,
    "-o", resources.appendingPathComponent("AppIcon.icns").path,
]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

print("Wrote \(resources.appendingPathComponent("AppIcon.icns").path)")
