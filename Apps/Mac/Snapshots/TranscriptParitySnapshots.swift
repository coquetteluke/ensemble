import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EnsembleKit

/// Snapshots of the task list card and of pictures on messages, in dark and light at the requested zoom:
/// - `task-list-running-*`: the card with done steps, the step in progress with its "1 running task" line, and steps
///   to do; under it the same list with two running tasks and with none.
/// - `message-pictures-*`: a message with a picture and text, a message that is only pictures, a message with a
///   picture and a file, and a picture whose file is gone.
/// - `composer-pictures-*`: the message box with a picture and a file waiting to be sent.
/// Called from `SnapshotRenderer.run`. The sample pictures are drawn here and saved in the temporary folder.
@MainActor
enum TranscriptParitySnapshots {
    @discardableResult
    static func render(to directory: URL, zoom: CGFloat) -> [String] {
        var written: [String] = []
        let suffix = zoom == 1 ? "" : "-\(Int((zoom * 100).rounded()))"
        let pictures = samplePictures()
        let store = SessionStore(engine: PreviewEngine())
        store.seed(PreviewData.seed())
        let window = WindowState()

        for scheme in [ColorScheme.dark, .light] {
            let tone = (scheme == .dark ? "dark" : "light") + suffix
            written += save("task-list-running-\(tone)", to: directory, width: 760, zoom: zoom, scheme: scheme) {
                TaskListStates()
            }
            written += save("message-pictures-\(tone)", to: directory, width: 760, zoom: zoom, scheme: scheme) {
                MessagePictures(pictures: pictures)
            }
            if let session = store.selected {
                // What is waiting to be sent: two pictures and a file.
                window.attachments[session.id] = Array(pictures.prefix(2)) + [URL(fileURLWithPath: "/tmp/release-notes.md")]
                written += save("composer-pictures-\(tone)", to: directory, width: 760, zoom: zoom, scheme: scheme) {
                    ComposerView(store: store, session: session, window: window,
                                 snapshotDraft: "Here is what it looks like on the phone")
                }
                window.attachments[session.id] = nil
            }
        }
        print("Rendered \(written.count) task list and picture snapshots:")
        for path in written { print(path) }
        return written
    }

    /// The plan tool calls of a session imported from the desktop app, replayed into the card's list.
    static let planItems: [TranscriptItem] = [
        .tool(ToolCallInfo(id: "plan-1", name: "mcp__ccd_turn__update_plan", title: "Plan", inputJSON: """
        {"items": [{"content": "Check the repository and how tools are registered", "status": "in_progress"},
                   {"content": "Start three agents (strip lookup, song tools, automation)", "status": "pending"},
                   {"content": "Start the last two agents (plug-ins, MIDI export)", "status": "pending"},
                   {"content": "Merge the five branches and build", "status": "pending"},
                   {"content": "Run the offline and live tests", "status": "pending"},
                   {"content": "Bump the version, write the changelog, commit", "status": "pending"}]}
        """, status: .succeeded)),
        .tool(ToolCallInfo(id: "plan-2", name: "mcp__ccd_turn__update_plan", title: "Plan", inputJSON: #"{"advance": true}"#, status: .succeeded)),
        .tool(ToolCallInfo(id: "plan-3", name: "mcp__ccd_turn__update_plan", title: "Plan", inputJSON: #"{"advance": true}"#, status: .succeeded)),
        .tool(ToolCallInfo(id: "plan-4", name: "mcp__ccd_turn__update_plan", title: "Plan", inputJSON: #"{"done": [3], "start": 4}"#, status: .succeeded)),
    ]

    /// Three pictures of different shapes, drawn once per run.
    static func samplePictures() -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ensemble-snapshot-pictures", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let specs: [(name: String, size: CGSize, colors: [CGColor])] = [
            ("window.png", CGSize(width: 960, height: 600), [CGColor(red: 0.20, green: 0.19, blue: 0.30, alpha: 1), CGColor(red: 0.55, green: 0.49, blue: 0.96, alpha: 1)]),
            ("phone.png", CGSize(width: 390, height: 780), [CGColor(red: 0.10, green: 0.25, blue: 0.28, alpha: 1), CGColor(red: 0.25, green: 0.72, blue: 0.66, alpha: 1)]),
            ("chart.png", CGSize(width: 700, height: 700), [CGColor(red: 0.30, green: 0.18, blue: 0.14, alpha: 1), CGColor(red: 0.95, green: 0.62, blue: 0.35, alpha: 1)]),
        ]
        return specs.compactMap { spec in
            let url = folder.appendingPathComponent(spec.name)
            guard let context = CGContext(data: nil, width: Int(spec.size.width), height: Int(spec.size.height), bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: spec.colors as CFArray, locations: [0, 1]) else { return nil }
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: spec.size.width, y: spec.size.height), options: [])
            // A few plain blocks, so the picture reads as a screenshot at thumbnail size.
            context.setFillColor(CGColor(gray: 1, alpha: 0.16))
            let unit = spec.size.width / 12
            context.fill(CGRect(x: unit, y: spec.size.height - unit * 2, width: spec.size.width - unit * 2, height: unit))
            context.fill(CGRect(x: unit, y: unit, width: unit * 4, height: spec.size.height - unit * 4))
            context.setFillColor(CGColor(gray: 1, alpha: 0.28))
            context.fill(CGRect(x: unit * 6, y: unit * 2, width: unit * 5, height: unit * 1.2))
            context.fill(CGRect(x: unit * 6, y: unit * 4, width: unit * 4, height: unit * 1.2))
            guard let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination) ? url : nil
        }
    }

    private static func save<V: View>(_ name: String, to directory: URL, width: CGFloat, zoom: CGFloat, scheme: ColorScheme,
                                      @ViewBuilder _ view: () -> V) -> [String] {
        let w = width * zoom
        let content = Canvas(width: w) { view() }
            .ensembleTheme()
            .environment(\.colorScheme, scheme)
            .environment(\.isSnapshot, true)
            .environment(\.zoom, zoom)
            .environment(SnapshotRenderer.power)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: w, height: nil)
        guard let image = renderer.cgImage else {
            print("Failed to render \(name)")
            return []
        }
        let url = directory.appendingPathComponent(name + ".png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return [] }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? [url.path] : []
    }

    private struct Canvas<Content: View>: View {
        let width: CGFloat
        @ViewBuilder let content: Content
        @Environment(\.theme) private var theme

        var body: some View {
            content
                .padding(theme.z(24))
                .frame(width: width, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .background(theme.background)
        }
    }
}

/// The card fed from `update_plan` calls: one running task, two, and none.
private struct TaskListStates: View {
    @Environment(\.theme) private var theme

    var body: some View {
        let list = TodoParser.latest(in: TranscriptParitySnapshots.planItems) ?? []
        VStack(alignment: .leading, spacing: theme.z(18)) {
            TaskListCard(items: list, runningTasks: 1)
            TaskListCard(items: Array(list.suffix(3)), runningTasks: 2)
            TaskListCard(items: Array(list.suffix(3)))
        }
    }
}

private struct MessagePictures: View {
    let pictures: [URL]
    @Environment(\.theme) private var theme

    var body: some View {
        let files = MessageAttachments.forFiles(pictures)
        let notes = MessageAttachment(id: "notes", kind: .file, name: "release-notes.md", path: "/tmp/release-notes.md")
        let missing = MessageAttachment(id: "gone", kind: .image, name: nil, path: "/tmp/ensemble-snapshot-pictures/not-there.png")
        let table: [String: [MessageAttachment]] = [
            "one": Array(files.prefix(1)),
            "two": Array(files.dropFirst()),
            "three": Array(files.prefix(1)) + [notes],
            "four": [missing],
        ]
        VStack(alignment: .leading, spacing: theme.z(18)) {
            UserBubble(id: "one", text: "The list is cut off on the right. Can you check the sidebar width?", date: Date().addingTimeInterval(-240),
                       alwaysShowActions: true)
            UserBubble(id: "two", text: "", date: Date().addingTimeInterval(-120))
            UserBubble(id: "three", text: "Same thing after the update, notes attached", date: Date().addingTimeInterval(-60))
            UserBubble(id: "four", text: "This picture's file is no longer on this Mac", date: Date())
        }
        .environment(\.messageAttachments, table)
        .environment(\.transcriptActions, TranscriptActions(historySupported: true))
    }
}
