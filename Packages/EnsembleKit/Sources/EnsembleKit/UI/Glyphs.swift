import SwiftUI

/// Thin outline icons for the context panel, drawn on a 24 x 24 grid and stroked at 1.25 pt
/// (SF Symbols' laptop and display glyphs are heavier than the reference).
public struct Glyph: View {
    public enum Kind: Sendable {
        case laptop, folder, monitor, note, code, document, chevronRight, chevronDown
    }

    let kind: Kind
    var size: CGFloat
    var lineWidth: CGFloat
    var color: Color?
    @Environment(\.theme) private var theme

    public init(_ kind: Kind, size: CGFloat = 18, lineWidth: CGFloat = 1.25, color: Color? = nil) {
        self.kind = kind
        self.size = size
        self.lineWidth = lineWidth
        self.color = color
    }

    public var body: some View {
        GlyphShape(kind: kind)
            .stroke(color ?? theme.textSecondary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// Icon for a file path: notes for Markdown and text, `</>` for code and config, a page for the rest.
    public static func kind(forPath path: String) -> Kind {
        switch (path as NSString).pathExtension.lowercased() {
        case "md", "markdown", "txt", "rtf": .note
        case "swift", "js", "ts", "tsx", "jsx", "json", "py", "go", "rs", "rb", "java", "kt", "c", "h", "m", "cpp",
             "css", "scss", "html", "yml", "yaml", "toml", "sh", "xml", "plist", "sql":
            .code
        default: .document
        }
    }
}

struct GlyphShape: Shape {
    let kind: Glyph.Kind

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let ox = rect.minX + (rect.width - 24 * s) / 2
        let oy = rect.minY + (rect.height - 24 * s) / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s)
        }

        var path = Path()
        switch kind {
        case .laptop:
            // Screen with rounded top corners, sitting on a wider rounded base.
            path.move(to: p(4.5, 15.5))
            path.addLine(to: p(4.5, 7))
            path.addArc(tangent1End: p(4.5, 5), tangent2End: p(6.5, 5), radius: 2 * s)
            path.addLine(to: p(17.5, 5))
            path.addArc(tangent1End: p(19.5, 5), tangent2End: p(19.5, 7), radius: 2 * s)
            path.addLine(to: p(19.5, 15.5))
            path.addRoundedRect(in: r(2, 15.5, 20, 3.75), cornerSize: CGSize(width: 1.6 * s, height: 1.6 * s))

        case .folder:
            path.move(to: p(2.5, 17.5))
            path.addLine(to: p(2.5, 6))
            path.addArc(tangent1End: p(2.5, 4), tangent2End: p(4.5, 4), radius: 2 * s)
            path.addLine(to: p(8.6, 4))
            path.addQuadCurve(to: p(10.2, 4.8), control: p(9.6, 4))
            path.addLine(to: p(11.6, 6.4))
            path.addQuadCurve(to: p(13.2, 7.2), control: p(12.2, 7.2))
            path.addLine(to: p(19.5, 7.2))
            path.addArc(tangent1End: p(21.5, 7.2), tangent2End: p(21.5, 9.2), radius: 2 * s)
            path.addLine(to: p(21.5, 17.5))
            path.addArc(tangent1End: p(21.5, 19.5), tangent2End: p(19.5, 19.5), radius: 2 * s)
            path.addLine(to: p(4.5, 19.5))
            path.addArc(tangent1End: p(2.5, 19.5), tangent2End: p(2.5, 17.5), radius: 2 * s)
            path.closeSubpath()

        case .monitor:
            path.addRoundedRect(in: r(2.5, 3.5, 19, 13), cornerSize: CGSize(width: 2.5 * s, height: 2.5 * s))
            path.move(to: p(9.5, 16.5))
            path.addLine(to: p(9.5, 20))
            path.addLine(to: p(14.5, 20))
            path.addLine(to: p(14.5, 16.5))

        case .note:
            // Rounded square with the bottom-right corner folded.
            path.move(to: p(13.5, 20.5))
            path.addLine(to: p(6.5, 20.5))
            path.addArc(tangent1End: p(3.5, 20.5), tangent2End: p(3.5, 17.5), radius: 3 * s)
            path.addLine(to: p(3.5, 6.5))
            path.addArc(tangent1End: p(3.5, 3.5), tangent2End: p(6.5, 3.5), radius: 3 * s)
            path.addLine(to: p(17.5, 3.5))
            path.addArc(tangent1End: p(20.5, 3.5), tangent2End: p(20.5, 6.5), radius: 3 * s)
            path.addLine(to: p(20.5, 13.5))
            path.addQuadCurve(to: p(13.5, 20.5), control: p(20, 20))
            path.move(to: p(20.5, 13.5))
            path.addLine(to: p(16.8, 13.5))
            path.addQuadCurve(to: p(13.5, 16.8), control: p(13.5, 13.5))
            path.addLine(to: p(13.5, 20.5))

        case .code:
            path.move(to: p(8, 7.5))
            path.addLine(to: p(3.5, 12))
            path.addLine(to: p(8, 16.5))
            path.move(to: p(16, 7.5))
            path.addLine(to: p(20.5, 12))
            path.addLine(to: p(16, 16.5))
            path.move(to: p(13.5, 4.5))
            path.addLine(to: p(10.5, 19.5))

        case .document:
            path.move(to: p(10.5, 20.5))
            path.addLine(to: p(7, 20.5))
            path.addArc(tangent1End: p(5, 20.5), tangent2End: p(5, 18.5), radius: 2 * s)
            path.addLine(to: p(5, 5.5))
            path.addArc(tangent1End: p(5, 3.5), tangent2End: p(7, 3.5), radius: 2 * s)
            path.addLine(to: p(15.5, 3.5))
            path.addArc(tangent1End: p(17.5, 3.5), tangent2End: p(17.5, 5.5), radius: 2 * s)
            path.addLine(to: p(17.5, 14.5))
            path.move(to: p(8.5, 7.5))
            path.addLine(to: p(13.5, 7.5))
            path.move(to: p(8.5, 10.5))
            path.addLine(to: p(11.5, 10.5))
            path.addRoundedRect(in: r(10.5, 14.5, 10, 6), cornerSize: CGSize(width: 1.6 * s, height: 1.6 * s))

        case .chevronRight:
            path.move(to: p(9, 6))
            path.addLine(to: p(15, 12))
            path.addLine(to: p(9, 18))

        case .chevronDown:
            path.move(to: p(6, 9))
            path.addLine(to: p(12, 15))
            path.addLine(to: p(18, 9))
        }
        return path
    }
}
