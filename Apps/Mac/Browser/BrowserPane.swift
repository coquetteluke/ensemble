import SwiftUI
import AppKit
import EnsembleKit

/// The browser in the window's right-hand pane: address bar, the page at full, tablet or phone width, a console, dev
/// servers from `.ensemble/launch.json`, and Send to agent (a screenshot, the console errors, a picked element).
struct BrowserPane: View {
    @Bindable var page: BrowserPage
    let store: SessionStore
    /// The session the page belongs to; Send to agent writes to it.
    let session: SessionModel
    var servers: DevServers = BrowserCenter.shared.servers
    var topInset: CGFloat = 52
    let onClose: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var showServers = false
    @State private var sendError: String?

    static let width: CGFloat = 700

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topInset)
            header
            HLine()
            addressBar
            progressLine
            if let pending = page.pendingStart {
                DevServerConfirmCard(page: page, pending: pending, servers: servers)
                HLine()
            }
            if let notice = page.notice {
                DevServerNoticeRow(page: page, notice: notice, store: store, servers: servers)
                HLine()
            }
            if let sendError {
                messageRow(sendError, symbol: "exclamationmark.triangle", tint: theme.warning) { self.sendError = nil }
                HLine()
            }
            webArea
            if page.picking || page.picked != nil {
                HLine()
                pickBar
            }
            if page.consoleOpen {
                HLine()
                BrowserConsoleView(page: page)
                    .frame(height: theme.z(220))
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.panel)
        .onAppear { if !isSnapshot { page.reloadLaunchConfig() } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: theme.z(4)) {
            Image(systemName: "globe")
                .font(theme.font(size: 12.5))
                .foregroundStyle(theme.textTertiary)
                .padding(.trailing, theme.z(4))
            Text(page.title.isEmpty ? "Browser" : page.title)
                .font(theme.font(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(page.title.isEmpty ? "Browser" : page.title)
            Spacer(minLength: theme.z(8))
            devServersButton
            consoleButton
            SendToAgentMenu(page: page, enabled: true, send: sendItem)
            IconButton("arrow.up.forward.app", help: "Open in your default browser", size: 26) { page.openExternally() }
                .disabled(!BrowserNavigationPolicy.opensExternally(page.url))
                .opacity(BrowserNavigationPolicy.opensExternally(page.url) ? 1 : 0.4)
            IconButton("xmark", help: "Close the browser (Option-Command-B)", size: 26, action: onClose)
        }
        .padding(.leading, theme.z(14))
        .padding(.trailing, theme.z(8))
        .frame(height: theme.z(38))
    }

    private var devServersButton: some View {
        IconButton("server.rack", help: "Dev servers from .ensemble/launch.json", size: 26, active: showServers || anyServerActive) {
            page.reloadLaunchConfig()
            showServers.toggle()
        }
        .overlay(alignment: .topTrailing) {
            if anyServerActive {
                StatusDot(theme.success, size: 6).offset(x: -theme.z(4), y: theme.z(4)).allowsHitTesting(false)
            }
        }
        .popover(isPresented: $showServers, arrowEdge: .bottom) {
            DevServersPopover(page: page, store: store, servers: servers) { showServers = false }
                .ensembleTheme()
                .environment(\.colorScheme, theme.isDark ? .dark : .light)
        }
    }

    private var anyServerActive: Bool {
        page.launch.entries.contains { page.status($0, servers: servers).isActive }
    }

    private var consoleButton: some View {
        let errors = page.errorCount
        return IconButton("terminal", help: page.consoleOpen ? "Hide the console" : "Show the console", size: 26, active: page.consoleOpen) {
            withAnimation(.easeOut(duration: 0.15)) { page.consoleOpen.toggle() }
        }
        .overlay(alignment: .topTrailing) {
            if errors > 0 && !page.consoleOpen {
                Text(errors > 99 ? "99+" : "\(errors)")
                    .font(theme.font(size: 9, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, theme.z(3.5))
                    .frame(minWidth: theme.z(14), minHeight: theme.z(14))
                    .background(Capsule().fill(theme.danger))
                    .offset(x: theme.z(3), y: -theme.z(1))
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Address bar

    private var addressBar: some View {
        HStack(spacing: theme.z(2)) {
            navButton("chevron.left", help: "Back", enabled: page.canGoBack) { page.goBack() }
            navButton("chevron.right", help: "Forward", enabled: page.canGoForward) { page.goForward() }
            if page.isLoading {
                navButton("xmark", help: "Stop loading", enabled: true) { page.stopLoading() }
            } else {
                navButton("arrow.clockwise", help: "Reload", enabled: page.hasPage) { page.reload() }
            }
            AddressField(page: page)
                .padding(.horizontal, theme.z(4))
            DeviceWidthMenu(page: page)
        }
        .padding(.horizontal, theme.z(8))
        .padding(.vertical, theme.z(6))
        .overlay(alignment: .bottomLeading) {
            if let error = page.addressError {
                Text(error)
                    .font(theme.font(size: 11))
                    .foregroundStyle(theme.danger)
                    .padding(.horizontal, theme.z(10))
                    .padding(.vertical, theme.z(3))
                    .background(RoundedRectangle(cornerRadius: theme.z(5), style: .continuous).fill(theme.popover))
                    .overlay(RoundedRectangle(cornerRadius: theme.z(5), style: .continuous).strokeBorder(theme.border))
                    .offset(x: theme.z(92), y: theme.z(22))
                    .zIndex(2)
            }
        }
        .zIndex(2)
    }

    private func navButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        IconButton(symbol, help: help, size: 26, action: action)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.35)
    }

    @ViewBuilder private var progressLine: some View {
        ZStack(alignment: .leading) {
            HLine()
            if page.isLoading {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(theme.accent)
                        .frame(width: proxy.size.width * max(0.05, page.progress), height: 2)
                        .animation(.easeOut(duration: 0.2), value: page.progress)
                }
                .frame(height: 2)
            }
        }
        .frame(height: 2, alignment: .top)
    }

    // MARK: Page

    private var webArea: some View {
        GeometryReader { proxy in
            let inset = page.device == .full ? 0 : theme.z(16)
            let layout = page.device.layout(available: proxy.size.width - inset * 2, scale: theme.scale)
            ZStack(alignment: .top) {
                (page.device == .full ? theme.background : theme.codeBackground)
                pageContent(zoom: layout.pageZoom)
                    .frame(width: page.device == .full ? proxy.size.width : layout.width)
                    .frame(maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: page.device == .full ? 0 : theme.z(10), style: .continuous))
                    .overlay {
                        if page.device != .full {
                            RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).strokeBorder(theme.border, lineWidth: 1)
                        }
                    }
                    .padding(.vertical, inset)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    @ViewBuilder private func pageContent(zoom: CGFloat) -> some View {
        if isSnapshot {
            if let image = page.snapshotImage {
                // Fills the page area from the top; the overlay does not change the area's size.
                Color.clear
                    .overlay(alignment: .top) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                    }
                    .clipped()
            } else {
                BrowserStartView(page: page, servers: servers)
            }
        } else if page.hasPage {
            BrowserWebView(page: page, pageZoom: zoom, isDark: theme.isDark)
                .overlay {
                    if let error = page.loadError {
                        loadErrorView(error)
                    }
                }
        } else {
            BrowserStartView(page: page, servers: servers)
        }
    }

    private func loadErrorView(_ error: String) -> some View {
        VStack(spacing: theme.z(10)) {
            Image(systemName: "exclamationmark.triangle")
                .font(theme.font(size: 22, weight: .light))
                .foregroundStyle(theme.textTertiary)
            Text("The page did not load")
                .font(theme.font(size: 14, weight: .medium))
                .foregroundStyle(theme.textPrimary)
            Text(error)
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Reload") { page.reload() }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(theme.z(24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.panel)
    }

    // MARK: Element picker

    private var pickBar: some View {
        HStack(spacing: theme.z(8)) {
            Image(systemName: "cursorarrow.rays")
                .font(theme.font(size: 12))
                .foregroundStyle(theme.accent)
            if page.picking {
                Text("Click an element on the page. Esc cancels.")
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: theme.z(8))
                Button("Cancel") { page.cancelPicking() }
                    .buttonStyle(SecondaryButtonStyle())
            } else if let picked = page.picked {
                Text(picked.summary)
                    .font(theme.font(size: 12, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Self.size(of: picked.html) + (picked.truncated ? ", cut" : ""))
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: theme.z(8))
                Button("Send to agent") {
                    send(BrowserAgentMessage.element(html: picked.html, summary: picked.summary, truncated: picked.truncated,
                                                     url: page.url?.absoluteString), [])
                    page.clearPicked()
                }
                .buttonStyle(PrimaryButtonStyle())
                IconButton("xmark", help: "Clear the picked element", size: 24) { page.clearPicked() }
            }
        }
        .padding(.horizontal, theme.z(12))
        .padding(.vertical, theme.z(7))
        .background(theme.elevated)
    }

    static func size(of html: String) -> String {
        let bytes = html.utf8.count
        return bytes < 1024 ? "\(bytes) bytes" : String(format: "%.1f KB", Double(bytes) / 1024)
    }

    private func messageRow(_ text: String, symbol: String, tint: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: theme.z(8)) {
            Image(systemName: symbol)
                .font(theme.font(size: 12))
                .foregroundStyle(tint)
            Text(text)
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: theme.z(4))
            IconButton("xmark", help: "Dismiss", size: 22, action: dismiss)
        }
        .padding(.horizontal, theme.z(12))
        .padding(.vertical, theme.z(8))
    }

    // MARK: Send to agent

    private func send(_ text: String, _ files: [URL]) {
        let sessionID = session.id
        Task { await store.send(text, files: files, to: sessionID) }
    }

    private func sendItem(_ item: SendToAgentMenu.Item) {
        sendError = nil
        let address = page.url?.absoluteString
        switch item {
        case .screenshot:
            Task {
                do {
                    let file = try await page.screenshotFile()
                    send(BrowserAgentMessage.screenshot(url: address ?? "the page", width: page.device), [file])
                } catch {
                    sendError = error.localizedDescription
                }
            }
        case .consoleErrors:
            if let text = BrowserAgentMessage.consoleErrors(page.console, url: address) { send(text, []) }
        case .pickElement:
            page.startPicking()
        }
    }
}

/// The address field: what the user types opens on Return; it follows the page while not being edited.
private struct AddressField: View {
    @Bindable var page: BrowserPage
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @FocusState private var focused: Bool
    @State private var draft = ""

    var body: some View {
        HStack(spacing: theme.z(6)) {
            Image(systemName: page.url?.scheme == "https" ? "lock" : "globe")
                .font(theme.font(size: 10.5))
                .foregroundStyle(theme.textTertiary)
            if isSnapshot {
                Text(page.addressText.isEmpty ? "Type an address, such as localhost:3000" : page.addressText)
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(page.addressText.isEmpty ? theme.textTertiary : theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: $draft, prompt: Text("Type an address, such as localhost:3000").foregroundStyle(theme.textTertiary))
                    .textFieldStyle(.plain)
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textPrimary)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .onSubmit {
                        page.go(draft)
                        if page.addressError == nil { focused = false }
                    }
                    .onKeyPress(.escape) {
                        draft = page.addressText
                        page.addressError = nil
                        focused = false
                        return .handled
                    }
            }
        }
        .padding(.horizontal, theme.z(9))
        .frame(height: theme.z(28))
        .background(
            RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
                .fill(theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.z(7), style: .continuous)
                .strokeBorder(focused ? theme.accent.opacity(0.7) : theme.border, lineWidth: 1)
        )
        .onAppear { draft = page.addressText }
        .onChange(of: page.addressText) { _, text in if !focused { draft = text } }
        .onChange(of: draft) { _, _ in if page.addressError != nil { page.addressError = nil } }
    }
}

/// Phone, tablet or full width.
private struct DeviceWidthMenu: View {
    @Bindable var page: BrowserPage
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            label
        } else {
            Menu {
                Picker("Width", selection: $page.device) {
                    ForEach(BrowserDeviceWidth.allCases) { width in
                        Label(width.label, systemImage: width.symbol).tag(width)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                label
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Page width: \(page.device.label)")
        }
    }

    private var label: some View {
        HStack(spacing: theme.z(3)) {
            Image(systemName: page.device.symbol)
                .font(theme.font(size: 12.5))
            Image(systemName: "chevron.down")
                .font(theme.font(size: 7.5, weight: .semibold))
        }
        .foregroundStyle(page.device == .full ? theme.textSecondary : theme.textPrimary)
        .frame(width: theme.z(38), height: theme.z(26))
        .contentShape(Rectangle())
    }
}

/// Send to agent: a screenshot, the console errors, or an element picked on the page.
struct SendToAgentMenu: View {
    enum Item { case screenshot, consoleErrors, pickElement }

    let page: BrowserPage
    let enabled: Bool
    let send: (Item) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            label
        } else {
            let errors = page.errorCount
            Menu {
                Button { send(.screenshot) } label: { Label("Screenshot of the page", systemImage: "camera") }
                    .disabled(!page.hasPage)
                Button { send(.consoleErrors) } label: {
                    Label(errors == 0 ? "Console errors (none)" : "Console errors (\(errors))", systemImage: "exclamationmark.bubble")
                }
                .disabled(errors == 0)
                Button { send(.pickElement) } label: { Label("Pick an element", systemImage: "cursorarrow.rays") }
                    .disabled(!page.hasPage)
            } label: {
                label
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!enabled)
            .help("Send to agent")
        }
    }

    private var label: some View {
        Image(systemName: "paperplane")
            .font(theme.font(size: 13.5))
            .foregroundStyle(theme.textSecondary)
            .frame(width: theme.z(26), height: theme.z(26))
            .contentShape(Rectangle())
    }
}

/// What the page area shows before a page is opened: the folder's dev servers, or how to add them.
struct BrowserStartView: View {
    let page: BrowserPage
    let servers: DevServers
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: theme.z(14)) {
            Spacer(minLength: theme.z(24))
            Image(systemName: "globe")
                .font(theme.font(size: 28, weight: .light))
                .foregroundStyle(theme.textTertiary)
            Text("Open a page")
                .font(theme.font(size: 15, weight: .medium))
                .foregroundStyle(theme.textPrimary)
            switch page.launch {
            case .loaded(let config) where !config.entries.isEmpty:
                Text("Type an address above, or start a dev server.")
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textSecondary)
                VStack(spacing: 0) {
                    ForEach(config.entries) { entry in
                        DevServerRow(page: page, entry: entry, servers: servers)
                        if entry.id != config.entries.last?.id { HLine() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).fill(theme.elevated))
                .overlay(RoundedRectangle(cornerRadius: theme.z(10), style: .continuous).strokeBorder(theme.border))
                .frame(maxWidth: theme.z(460))
            case .failed(let reason):
                Text(reason)
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.warning)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: theme.z(420))
            default:
                Text("Type an address above, such as localhost:3000. To start dev servers from here, add .ensemble/launch.json to this folder.")
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: theme.z(400))
            }
            Spacer(minLength: theme.z(24))
        }
        .padding(.horizontal, theme.z(20))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }
}
