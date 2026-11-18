import AVFoundation
import EnsembleKit
import SwiftUI
import VisionKit

/// First run: scan the QR code from the Mac, or paste the pairing code.
struct PairingView: View {
    @Environment(RemoteAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// True when shown as a sheet from Settings to pair again.
    var isSheet = false

    @State private var scanning = false
    @State private var pasted = ""
    @State private var error: String?
    @State private var cameraDenied = false

    private var scannerAvailable: Bool {
        DataScannerViewController.isSupported
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if scanning {
                    scannerCard
                } else {
                    scanButton
                }
                pasteCard
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(RemoteTheme.danger)
                }
                if !isSheet {
                    Button("Try with sample data") { model.startDemo() }
                        .font(.footnote)
                        .foregroundStyle(RemoteTheme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
            }
            .padding(20)
            // Readable line length on the wide inner screen; full width on a phone.
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .remoteScreen()
        .toolbar {
            if isSheet {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.accentColor)
                .padding(.bottom, 6)
            Text("Pair with your Mac")
                .font(.title.weight(.semibold))
                .foregroundStyle(RemoteTheme.primaryText)
            Text("On your Mac, open Ensemble, turn on Remote Control and choose Show pairing code. Keep Tailscale on on both devices to connect from anywhere.")
                .font(.subheadline)
                .foregroundStyle(RemoteTheme.secondaryText)
        }
        .padding(.top, isSheet ? 0 : 40)
    }

    private var scanButton: some View {
        Button {
            Task { await startScanning() }
        } label: {
            Label("Scan pairing code", systemImage: "qrcode.viewfinder")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .disabled(!scannerAvailable)
        .overlay(alignment: .bottom) {
            if !scannerAvailable {
                Text("This device cannot scan codes. Paste the code instead.")
                    .font(.caption)
                    .foregroundStyle(RemoteTheme.tertiaryText)
                    .offset(y: 26)
            } else if cameraDenied {
                Text("Allow camera access in Settings to scan.")
                    .font(.caption)
                    .foregroundStyle(RemoteTheme.warning)
                    .offset(y: 26)
            }
        }
        .padding(.bottom, scannerAvailable && !cameraDenied ? 0 : 22)
    }

    private var scannerCard: some View {
        ZStack(alignment: .topTrailing) {
            QRScannerView { code in
                scanning = false
                submit(code)
            }
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: RemoteTheme.cornerRadius, style: .continuous))
            Button {
                scanning = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
            }
            .padding(10)
            .accessibilityLabel("Stop scanning")
        }
    }

    private var pasteCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Or paste the pairing code")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(RemoteTheme.primaryText)
            TextField("Pairing code", text: $pasted, axis: .vertical)
                .font(.system(.footnote, design: .monospaced))
                .lineLimit(3...6)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .background(RemoteTheme.cardRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack {
                Button("Paste") {
                    if let text = UIPasteboard.general.string { pasted = text }
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Pair") { submit(pasted) }
                    .buttonStyle(.borderedProminent)
                    .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .remoteCard()
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
            if isSheet { dismiss() }
        } catch {
            self.error = error.localizedDescription
        }
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
            isHighlightingEnabled: true)
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
