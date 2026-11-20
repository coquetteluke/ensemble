#if DEBUG
import EnsembleKit
import SwiftUI
import UIKit

/// Renders real UIKit-hosted iPhone Duo unfolded split-view screens (regular horizontalSizeClass,
/// 951x669 landscape side-by-side and 669x951 portrait) into PNG files when launched with
/// `-render-snapshots <dir>`. Used for visual GUI audits on the iOS simulator.
@MainActor
enum RemoteSnapshots {
    static func requestedDirectory() -> URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-render-snapshots"), idx + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[idx + 1], isDirectory: true)
    }

    static func run(outputDirectory: URL) async {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let model = RemoteAppModel()
        model.startDemo()
        guard let client = model.client else { return }

        // Wait for demo hub, rooms, and usage to finish loading.
        for _ in 0..<40 {
            if !client.sessions.isEmpty && !client.rooms.isEmpty && client.usage != nil { break }
            try? await Task.sleep(for: .milliseconds(50))
        }

        let cases: [(name: String, width: CGFloat, height: CGFloat, setup: @MainActor () async -> Void)] = [
            ("duo-split-hub", 951, 669, {
                model.hubPath = []
                model.roomsPath = []
                model.showList(.hub)
                model.tab = .hub
            }),
            ("duo-split-chat", 951, 669, {
                model.showList(.hub)
                model.open(ChatRoute(sessionID: RemoteDemoData.IDs.fixSession, title: "Fix login redirect loop"), from: .hub)
                try? await client.open(sessionID: RemoteDemoData.IDs.fixSession)
            }),
            ("duo-split-roomchat", 951, 669, {
                model.showList(.rooms)
                model.open(ChatRoute(sessionID: RemoteDemoData.IDs.roomSession, title: "Design the sync API"), from: .rooms)
                try? await client.open(sessionID: RemoteDemoData.IDs.roomSession)
            }),
            ("duo-split-usage", 951, 669, {
                model.showList(.hub)
                model.tab = .usage
            }),
            ("duo-split-settings", 951, 669, {
                model.showList(.hub)
                model.tab = .settings
            }),
            ("duo-split-portrait-chat", 669, 951, {
                model.showList(.hub)
                model.open(ChatRoute(sessionID: RemoteDemoData.IDs.fixSession, title: "Fix login redirect loop"), from: .hub)
                try? await client.open(sessionID: RemoteDemoData.IDs.fixSession)
            }),
        ]

        for style in [(name: "dark", ui: UIUserInterfaceStyle.dark, scheme: ColorScheme.dark),
                      (name: "light", ui: UIUserInterfaceStyle.light, scheme: ColorScheme.light)] {
            for item in cases {
                await item.setup()
                try? await Task.sleep(for: .milliseconds(250))

                let view = SplitRootView(client: client)
                    .environment(model)
                    .remoteThemeEnvironment()
                    .environment(\.horizontalSizeClass, .regular)
                    .environment(\.colorScheme, style.scheme)

                let png = await render(view, size: CGSize(width: item.width, height: item.height), style: style.ui)
                if let png {
                    let url = outputDirectory.appendingPathComponent("\(item.name)-\(style.name).png")
                    try? png.write(to: url)
                }
            }
        }

        let marker = outputDirectory.appendingPathComponent("DONE")
        try? Data("ok\n".utf8).write(to: marker)
    }

    private static func render<V: View>(_ view: V, size: CGSize, style: UIUserInterfaceStyle) async -> Data? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return nil }

        let controller = UIHostingController(rootView: view)
        controller.overrideUserInterfaceStyle = style
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.backgroundColor = style == .dark
            ? UIColor(red: 0.11, green: 0.106, blue: 0.102, alpha: 1)
            : UIColor(red: 0.98, green: 0.976, blue: 0.969, alpha: 1)

        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = controller
        window.isHidden = false
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        try? await Task.sleep(for: .milliseconds(450))
        controller.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            if !window.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true) {
                window.layer.render(in: ctx.cgContext)
            }
        }
        window.isHidden = true
        window.rootViewController = nil
        return image.pngData()
    }
}
#endif
