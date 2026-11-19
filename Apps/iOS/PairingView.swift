import AVFoundation
import EnsembleKit
import SwiftUI
import VisionKit

/// First run and re-pairing: live QR scanner with paste-code sheet and Demo entry.
struct PairingView: View {
    @Environment(RemoteAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var isSheet = false

    @State private var scanning = false
    @State private var showPasteSheet = false
    @State private var pasted = ""
    @State private var error: String?
    @State private var cameraDenied = false

    private var scannerAvailable: Bool { DataScannerViewController.isSupported }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PairingHeader(isSheet: isSheet)

                if scanning {
                    PairingScannerCard(
                        onCode: { code in
                            scanning = false
                            submit(code)
                        },
                        onClose: { scanning = false }
                    )
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            Task { await startScanning() }
                        } label: {
                            Label("Scan pairing code", systemImage: "qrcode.viewfinder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(RemotePrimaryButtonStyle(minHeight: 50))
                        .disabled(!scannerAvailable)

                        if !scannerAvailable {
                            Text("Camera scanning is unavailable on this device.")
                                .font(RemoteTheme.font(size: 12.5, relativeTo: .caption))
                                .foregroundStyle(RemoteTheme.tertiaryText)
                        } else if cameraDenied {
                            Text("Allow camera access in Settings to scan.")
                                .font(RemoteTheme.font(size: 12.5, relativeTo: .caption))
                                .foregroundStyle(RemoteTheme.warning)
                        }

                        Button {
                            error = nil
                            showPasteSheet = true
                        } label: {
                            Label("Paste pairing code", systemImage: "doc.on.clipboard")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(RemoteSecondaryButtonStyle(minHeight: 48))
                    }
                    .remoteCard(padding: 16)
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(RemoteTheme.font(size: 13.5, relativeTo: .footnote))
                        .foregroundStyle(RemoteTheme.danger)
                }

                if !isSheet {
                    Button {
                        model.startDemo()
                    } label: {
                        Text("Try Demo")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RemoteSecondaryButtonStyle())
                }
            }
            .padding(20)
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity)
        }
        .remoteScreen()
        .toolbar {
            if isSheet {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showPasteSheet) {
            PastePairingSheet(
                code: $pasted,
                error: $error,
                onPair: { submit(pasted) }
            )
            .remoteThemeEnvironment()
        }
    }

    private func startScanning() async {
        error = nil
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraDenied = false
            scanning = true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            cameraDenied = !granted
            scanning = granted
        default:
            cameraDenied = true
        }
    }

    private func submit(_ code: String) {
        do {
            try model.pair(with: code)
            error = nil
            showPasteSheet = false
            if isSheet { dismiss() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct PairingHeader: View {
    let isSheet: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ConstellationSpinner(size: 46, frozenAt: 1.1)
                .padding(.bottom, 4)
            Text("Pair with your Mac")
                .font(RemoteTheme.font(size: 26, weight: .semibold, relativeTo: .title))
                .foregroundStyle(RemoteTheme.primaryText)
            Text("Open Ensemble > Settings > Remote Control on your Mac.")
                .font(RemoteTheme.font(size: 14.5, relativeTo: .subheadline))
                .foregroundStyle(RemoteTheme.secondaryText)
        }
        .padding(.top, isSheet ? 4 : 32)
    }
}

private struct PairingScannerCard: View {
    let onCode: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            QRScannerView(onCode: onCode)
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: RemoteTheme.cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: RemoteTheme.cornerRadius, style: .continuous)
                        .strokeBorder(RemoteTheme.border, lineWidth: 1)
                )

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                    .frame(minWidth: RemoteTheme.minTapTarget, minHeight: RemoteTheme.minTapTarget)
            }
            .padding(6)
            .accessibilityLabel("Stop scanning")
        }
    }
}

private struct PastePairingSheet: View {
    @Binding var code: String
    @Binding var error: String?
    let onPair: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    private var trimmedEmpty: Bool {
        code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Pairing code", text: $code, axis: .vertical)
                    .font(RemoteTheme.font(size: 13.5, design: .monospaced, relativeTo: .footnote))
                    .lineLimit(4...8)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .padding(12)
                    .background(RemoteTheme.cardRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(RemoteTheme.border, lineWidth: 1)
                    )

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(RemoteTheme.font(size: 13, relativeTo: .footnote))
                        .foregroundStyle(RemoteTheme.danger)
                }

                HStack(spacing: 10) {
                    Button("Paste") {
                        if let text = UIPasteboard.general.string {
                            code = text
                            error = nil
                        }
                    }
                    .buttonStyle(RemoteSecondaryButtonStyle())

                    Spacer()

                    Button("Pair", action: onPair)
                        .buttonStyle(RemotePrimaryButtonStyle())
                        .disabled(trimmedEmpty)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .remoteScreen()
            .navigationTitle("Paste pairing code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }
}

/// VisionKit live QR scanner. Calls `onCode` once with the first QR payload it sees.
struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
        if !scanner.isScanning, DataScannerViewController.isAvailable {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void
        private var delivered = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            deliver(addedItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            deliver([item])
        }

        private func deliver(_ items: [RecognizedItem]) {
            guard !delivered else { return }
            for item in items {
                if case .barcode(let barcode) = item, let text = barcode.payloadStringValue {
                    delivered = true
                    onCode(text)
                    return
                }
            }
        }
    }
}
