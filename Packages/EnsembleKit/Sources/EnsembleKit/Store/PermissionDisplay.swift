import Foundation

/// Text helpers for showing a permission prompt honestly: nothing an agent writes can hide part of
/// a command, reorder it on screen, or pose as the rule "Always allow" saves.
public enum PermissionDisplay {
    /// Longest command, in characters, that the Hub may offer to approve with one tap.
    public static let quickApprovalLimit = 120

    /// `text` with characters that could hide or reorder what is shown written out as `\u{XXXX}`:
    /// control characters, zero-width and text-direction marks, other invisible format characters
    /// and unusual spaces. Newlines and tabs stay real when `keepLineBreaks` is true and are
    /// written as `\n` and `\t` otherwise.
    public static func visible(_ text: String, keepLineBreaks: Bool = true) -> String {
        var out = String.UnicodeScalarView()
        func escape(_ scalar: Unicode.Scalar) {
            out.append(contentsOf: String(format: "\\u{%04X}", scalar.value).unicodeScalars)
        }
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n" where keepLineBreaks, "\t" where keepLineBreaks, " ":
                out.append(scalar)
            case "\n":
                out.append(contentsOf: "\\n".unicodeScalars)
            case "\t":
                out.append(contentsOf: "\\t".unicodeScalars)
            case "\r":
                out.append(contentsOf: "\\r".unicodeScalars)
            default:
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator,
                     .surrogate, .privateUse, .unassigned:
                    escape(scalar)
                default:
                    out.append(scalar)
                }
            }
        }
        return String(out)
    }

    /// The rules "Always allow" saves, one display line each, every one made visible in full.
    public static func patterns(_ request: PermissionRequest) -> [String] {
        (request.alwaysPatterns ?? [])
            .filter { !$0.isEmpty }
            .map { visible($0, keepLineBreaks: false) }
    }

    /// True when the whole command is short enough to read at a glance, so a one-tap approval
    /// (Hub quick actions) shows everything being approved. Longer or multi-line requests must be
    /// opened and read first.
    public static func fitsQuickApproval(_ request: PermissionRequest) -> Bool {
        let title = visible(request.title, keepLineBreaks: false)
        return title.count <= quickApprovalLimit && title == request.title
    }
}
