import SwiftUI
import AppKit
import EnsembleKit

/// The console under the page: the page's console calls and errors, dev server output, and Ensemble's own notes.
struct BrowserConsoleView: View {
    let page: BrowserPage
    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var errorsOnly = false

    var body: some View {
        VStack(spacing: 0) {
            header
            HLine()
            lines
        }
        .background(theme.codeBackground)
    }

    private var header: some View {
        HStack(spacing: theme.z(10)) {
            Text("Console")
                .font(theme.font(size: 12, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            count(page.errorCount, symbol: "xmark.octagon.fill", color: theme.danger, label: "errors")
            count(page.warningCount, symbol: "exclamationmark.triangle.fill", color: theme.warning, label: "warnings")
            Spacer(minLength: theme.z(6))
            Button {
                errorsOnly.toggle()
            } label: {
                Text("Errors only")
                    .font(theme.font(size: 11.5, weight: errorsOnly ? .semibold : .regular))
                    .foregroundStyle(errorsOnly ? theme.textPrimary : theme.textSecondary)
                    .padding(.horizontal, theme.z(7))
                    .frame(height: theme.z(22))
                    .background(RoundedRectangle(cornerRadius: theme.z(5), style: .continuous).fill(errorsOnly ? theme.selection : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(errorsOnly ? "Show every line" : "Show errors only")
            IconButton("trash", help: "Clear the console", size: 22) { page.clearConsole() }
            IconButton("chevron.down", help: "Hide the console", size: 22) {
                withAnimation(.easeOut(duration: 0.15)) { page.consoleOpen = false }
            }
        }
        .padding(.leading, theme.z(12))
        .padding(.trailing, theme.z(6))
        .frame(height: theme.z(30))
    }

    private func count(_ value: Int, symbol: String, color: Color, label: String) -> some View {
        HStack(spacing: theme.z(3)) {
            Image(systemName: symbol)
                .font(theme.font(size: 9.5))
                .foregroundStyle(value > 0 ? color : theme.textTertiary)
            Text("\(value)")
                .font(theme.font(size: 11))
                .monospacedDigit()
                .foregroundStyle(value > 0 ? theme.textSecondary : theme.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
    }

    private var shown: [BrowserConsoleLine] {
        errorsOnly ? page.console.filter { $0.level == .error } : page.console
    }

    @ViewBuilder private var lines: some View {
        let shown = self.shown
        if shown.isEmpty {
            Text(errorsOnly ? "No errors" : "Nothing logged yet")
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isSnapshot {
            // The newest lines, kept at the bottom like the scrolled console.
            Color.clear
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(shown.suffix(14)) { line in ConsoleLineRow(line: line) }
                    }
                    .padding(.bottom, theme.z(4))
                }
                .clipped()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown) { line in ConsoleLineRow(line: line).id(line.id) }
                    }
                }
                .onAppear { proxy.scrollTo(shown.last?.id, anchor: .bottom) }
                .onChange(of: shown.last?.id) { _, id in proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }
}

private struct ConsoleLineRow: View {
    let line: BrowserConsoleLine
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.z(7)) {
            Image(systemName: symbol)
                .font(theme.font(size: 9.5))
                .foregroundStyle(color)
                .frame(width: theme.z(12))
            if let tag {
                Text(tag)
                    .font(theme.font(size: 10, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, theme.z(5))
                    .padding(.vertical, theme.z(1))
                    .background(Capsule().fill(theme.elevated))
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(line.text)
                .font(theme.font(size: 11.5, design: .monospaced))
                .foregroundStyle(textColor)
                .lineLimit(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .selectableText()
        }
        .padding(.horizontal, theme.z(12))
        .padding(.vertical, theme.z(3))
        .background(background)
    }

    private var tag: String? {
        switch line.source {
        case .page: nil
        case .server(let name): name
        case .browser: "Ensemble"
        }
    }

    private var symbol: String {
        switch line.level {
        case .error: "xmark.octagon.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        case .log, .debug: "chevron.right"
        }
    }

    private var color: Color {
        switch line.level {
        case .error: theme.danger
        case .warn: theme.warning
        case .info: theme.contextBlue
        case .log, .debug: theme.textTertiary
        }
    }

    private var textColor: Color {
        switch line.level {
        case .error: theme.danger
        case .debug: theme.textTertiary
        default: theme.textPrimary
        }
    }

    private var background: Color {
        switch line.level {
        case .error: theme.danger.opacity(0.07)
        case .warn: theme.warning.opacity(0.06)
        default: .clear
        }
    }
}
