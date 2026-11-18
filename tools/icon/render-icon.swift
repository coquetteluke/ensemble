// Renders Ensemble's app icon ("Constellation") to PNG files.
// Usage: swift tools/icon/render-icon.swift <output-dir>
// Writes icon-mac-1024.png (macOS: rounded square inset on a transparent canvas, with shadow)
// and icon-ios-1024.png (iOS: full-bleed square; iOS applies its own mask).
import AppKit
import SwiftUI

struct ConstellationArt: View {
    // Node positions in a 1000 x 1000 design space.
    let nodes: [(CGPoint, Color, CGFloat)] = [
        (CGPoint(x: 300, y: 300), Color(red: 1, green: 1, blue: 1), 74),
        (CGPoint(x: 700, y: 360), Color(red: 0.18, green: 0.83, blue: 0.75), 74),
        (CGPoint(x: 430, y: 700), Color(red: 0.96, green: 0.73, blue: 0.26), 74),
        (CGPoint(x: 735, y: 690), Color(red: 0.96, green: 0.45, blue: 0.71), 60),
    ]
    let edges: [(Int, Int)] = [(0, 1), (0, 2), (1, 2), (1, 3), (2, 3)]

    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 1000
            func p(_ pt: CGPoint) -> CGPoint { CGPoint(x: pt.x * s, y: pt.y * s) }
            // Lines with a soft halo.
            for (a, b) in edges {
                var path = Path()
                path.move(to: p(nodes[a].0))
                path.addLine(to: p(nodes[b].0))
                ctx.stroke(path, with: .color(Color(red: 0.66, green: 0.61, blue: 1).opacity(0.25)), style: StrokeStyle(lineWidth: 46 * s, lineCap: .round))
                ctx.stroke(path, with: .color(Color(red: 0.72, green: 0.67, blue: 1)), style: StrokeStyle(lineWidth: 20 * s, lineCap: .round))
            }
            // Nodes: halo, body with a top-left highlight.
            for (pt, color, r) in nodes {
                let c = p(pt)
                let rr = r * s
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - rr * 1.55, y: c.y - rr * 1.55, width: rr * 3.1, height: rr * 3.1)),
                         with: .color(color.opacity(0.16)))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)),
                         with: .radialGradient(Gradient(colors: [color.mix(with: .white, by: 0.35), color, color.mix(with: .black, by: 0.18)]),
                                               center: CGPoint(x: c.x - rr * 0.35, y: c.y - rr * 0.4), startRadius: 0, endRadius: rr * 1.5))
            }
        }
    }
}

struct IconBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.24, green: 0.19, blue: 0.56), Color(red: 0.11, green: 0.08, blue: 0.27)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // Glass sheen across the top.
            LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0)], startPoint: .top, endPoint: .center)
        }
    }
}

struct MacIcon: View {
    var body: some View {
        // macOS grid: 824 pt rounded square centered on a 1024 canvas.
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(.black.opacity(0.35))
                .frame(width: 824, height: 824)
                .offset(y: 12)
                .blur(radius: 18)
            ZStack {
                IconBackground()
                ConstellationArt().padding(70)
            }
            .frame(width: 824, height: 824)
            .clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 3))
        }
        .frame(width: 1024, height: 1024)
    }
}

struct IOSIcon: View {
    var body: some View {
        ZStack {
            IconBackground()
            ConstellationArt().padding(150)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor
func write<V: View>(_ view: V, to url: URL) throws {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    guard let cg = renderer.cgImage else { throw NSError(domain: "icon", code: 1) }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let data = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "icon", code: 2) }
    try data.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try MainActor.assumeIsolated {
    try write(MacIcon(), to: out.appendingPathComponent("icon-mac-1024.png"))
    try write(IOSIcon(), to: out.appendingPathComponent("icon-ios-1024.png"))
}
print("wrote icons to \(out.path)")
