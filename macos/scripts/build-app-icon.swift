#!/usr/bin/env swift
//
// Compose the Hark mark onto a standard macOS Big Sur+ icon template
// and emit the full size matrix the asset catalog expects.
//
//   swift scripts/build-app-icon.swift [source.png] [bg-hex] [output-dir]
//   (run from the /macos directory)
//
// Defaults:
//   source.png  → ../assets/hark-mark.png    (canonical brand artwork)
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
    let sourcePath = args.count >= 2 ? args[1] : "../assets/hark-mark.png"
    // Pure white squircle so the H mark reads as the only "logo" element.
    // Matches the Notes / Bear / Reminders / Things aesthetic of a flat
    // light fill with a dark glyph.
    let bgHex = args.count >= 3 ? args[2] : "#FFFFFF"
    let outputDir = args.count >= 4 ? args[3] : "Hark/Resources/Assets.xcassets/AppIcon.appiconset"
    // Tint the source mark (assumed black-on-transparent) to this color so
    // it reads against the white background.
    let tintHex = args.count >= 5 ? args[4] : "#0A0A0A"
    // Additional location to drop AppIcon.icns. macOS Tahoe (26+) renders
    // .car-only icons through its Liquid Glass compatibility layer (visible
    // gray plate behind the squircle). Apps that ship a hand-crafted
    // AppIcon.icns alongside Assets.car (Notes, Mail, etc.) are rendered
    // without the chrome — so we generate one here.
    let icnsDir = args.count >= 6 ? args[5] : "Hark/Resources"

    guard let source = NSImage(contentsOfFile: sourcePath) else {
        FileHandle.standardError.write(Data("error: could not load \(sourcePath)\n".utf8))
        exit(1)
    }
    let bg = nsColor(bgHex)
    let tint = nsColor(tintHex)

    let sizes = [16, 32, 64, 128, 256, 512, 1024]
    var pngBySize: [Int: Data] = [:]
    for size in sizes {
        let url = URL(fileURLWithPath: outputDir).appendingPathComponent("icon_\(size).png")
        guard let data = renderPNG(source: source, background: bg, tint: tint, size: CGFloat(size)) else {
            FileHandle.standardError.write(Data("error: render failed at \(size)\n".utf8))
            continue
        }
        try? data.write(to: url)
        pngBySize[size] = data
        print("wrote \(url.path) (\(data.count) bytes)")
    }

    buildICNS(pngBySize: pngBySize, outputDir: icnsDir)
}

/// Build AppIcon.icns from the rendered PNGs via /usr/bin/iconutil. We
/// can't write the icns binary format by hand, but iconutil happily takes
/// a populated .iconset directory and emits the file.
@MainActor
private func buildICNS(pngBySize: [Int: Data], outputDir: String) {
    // Mapping from .iconset filename to source PNG size. Apple expects both
    // 1x and 2x variants for each logical size (16, 32, 128, 256, 512).
    let mapping: [(String, Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024)
    ]

    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("hark-AppIcon-\(UUID().uuidString).iconset", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    for (name, size) in mapping {
        guard let data = pngBySize[size] else { continue }
        try? data.write(to: tmp.appendingPathComponent(name))
    }

    let outURL = URL(fileURLWithPath: outputDir).appendingPathComponent("AppIcon.icns")
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    proc.arguments = ["--convert", "icns", "--output", outURL.path, tmp.path]
    do {
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus == 0 {
            let size = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
            print("wrote \(outURL.path) (\(size) bytes)")
        } else {
            FileHandle.standardError.write(Data("iconutil failed: status \(proc.terminationStatus)\n".utf8))
        }
    } catch {
        FileHandle.standardError.write(Data("iconutil error: \(error)\n".utf8))
    }
}

@MainActor
private func renderPNG(source: NSImage, background: NSColor, tint: NSColor, size: CGFloat) -> Data? {
    let view = IconCanvas(
        source: source,
        background: Color(nsColor: background),
        tint: Color(nsColor: tint)
    )
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

/// Pre-shaped white squircle with TRANSPARENT corners — the pattern Chrome,
/// Spotify, Notes, and every other "fills the Dock slot cleanly" app uses.
/// Filling the canvas edge-to-edge makes Tahoe apply its compatibility
/// chrome (visible gray plate around the icon); drawing our own squircle
/// with transparent margins skips that path entirely.
///   - 1024 canvas, ~100px transparent margin (Apple production grid)
///   - squircle cornerRadius = 22.37% of squircle width
///   - artwork inset 18% inside the squircle so the H clears the corners
private struct IconCanvas: View {
    let source: NSImage
    let background: Color
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let outerPad = s * (100.0 / 1024.0)
            let inner = s - 2 * outerPad
            let radius = inner * 0.2237
            let artPadding = inner * 0.18

            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(background)
                .overlay(
                    Image(nsImage: source)
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .foregroundStyle(tint)
                        .padding(artPadding)
                )
                .padding(outerPad)
        }
    }
}

MainActor.assumeIsolated { main() }
