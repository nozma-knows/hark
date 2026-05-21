#!/usr/bin/env swift
//
// Compose the Hark mark onto a standard macOS Big Sur+ icon template
// and emit the full size matrix the asset catalog expects.
//
//   swift scripts/build-app-icon.swift [source.png] [bg-hex] [output-dir]
//
// Defaults:
//   source.png  → scripts/icon-source/hark-mark.png
//   bg-hex      → #FFFFFF (clean white, matches Notes / Bear / Reminders)
//   output-dir  → Hark/Resources/Assets.xcassets/AppIcon.appiconset
//
// Why this exists: macOS dock icons are not "logo on a square" — they
// sit inside a continuous-corner rounded rectangle (cornerRadius ≈
// 22.37% of the inner shape) inset ~10% from the canvas. Apps that
// ignore the template look glaringly non-native in the Dock.
//

import AppKit
import SwiftUI

@MainActor
func main() {
    let args = CommandLine.arguments
    let sourcePath = args.count >= 2 ? args[1] : "scripts/icon-source/hark-mark.png"
    let bgHex = args.count >= 3 ? args[2] : "#FFFFFF"
    let outputDir = args.count >= 4 ? args[3] : "Hark/Resources/Assets.xcassets/AppIcon.appiconset"

    guard let source = NSImage(contentsOfFile: sourcePath) else {
        FileHandle.standardError.write(Data("error: could not load \(sourcePath)\n".utf8))
        exit(1)
    }
    let bg = nsColor(bgHex)

    let sizes = [16, 32, 64, 128, 256, 512, 1024]
    for size in sizes {
        let url = URL(fileURLWithPath: outputDir).appendingPathComponent("icon_\(size).png")
        guard let data = renderPNG(source: source, background: bg, size: CGFloat(size)) else {
            FileHandle.standardError.write(Data("error: render failed at \(size)\n".utf8))
            continue
        }
        try? data.write(to: url)
        print("wrote \(url.path) (\(data.count) bytes)")
    }
}

@MainActor
private func renderPNG(source: NSImage, background: NSColor, size: CGFloat) -> Data? {
    let view = IconCanvas(source: source, background: Color(nsColor: background))
        .frame(width: size, height: size)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    renderer.isOpaque = false
    guard
        let cgImage = renderer.cgImage else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])
}

private func nsColor(_ hex: String) -> NSColor {
    var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if h.hasPrefix("#") { h.removeFirst() }
    let v = UInt32(h, radix: 16) ?? 0xFFFFFF
    return NSColor(
        srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
        green: CGFloat((v >> 8) & 0xFF) / 255,
        blue: CGFloat(v & 0xFF) / 255,
        alpha: 1
    )
}

/// Apple's macOS icon grid, expressed proportionally so the same view
/// renders correctly at every size. The numbers come from Apple's HIG
/// "macOS Production Templates":
///   - 1024 canvas, 100px outer pad → squircle 824×824
///   - squircle cornerRadius = 22.37% of squircle width
///   - artwork inset ~18% of canvas (taste — keeps the mark from kissing
///     the edge of the squircle)
private struct IconCanvas: View {
    let source: NSImage
    let background: Color

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let outerPad = s * (100.0 / 1024.0)
            let inner = s - 2 * outerPad
            let radius = inner * 0.2237
            let artPadding = s * 0.20

            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(background)
                .overlay(
                    Image(nsImage: source)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(artPadding)
                )
                .padding(outerPad)
        }
    }
}

MainActor.assumeIsolated { main() }
