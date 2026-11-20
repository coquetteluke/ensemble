import SwiftUI
import AppKit
import AVFoundation
import Speech
import Security
import EnsembleKit

/// Why dictation cannot run, and where to fix it.
struct DictationProblem: Equatable {
    let message: String
    /// A System Settings pane that fixes it, when there is one.
    var settingsURL: URL?

    static let microphoneDenied = DictationProblem(
        message: "Microphone access is off for Ensemble. Turn it on in System Settings > Privacy & Security > Microphone.",
        settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"))
    static let speechDenied = DictationProblem(
        message: "Speech recognition is off for Ensemble. Turn it on in System Settings > Privacy & Security > Speech Recognition.",
        settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"))
    static let restricted = DictationProblem(message: "Dictation is restricted on this Mac.")
    static let notInThisBuild = DictationProblem(message: "This build of Ensemble does not ask for microphone access, so it cannot dictate.")
}

/// Voice dictation for the composer, with Apple's Speech framework (on-device when the Mac supports it for the
/// language). Text streams into the composer at the cursor; press the button again or Esc to stop.
@Observable @MainActor
final class DictationController {
    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case unavailable(DictationProblem)
    }

    private(set) var phase: Phase = .idle
    /// Microphone level, 0 to 1, for the button.
    private(set) var level: Double = 0

    /// The composer marks where dictated text goes (the cursor or selection) when recording starts.
    @ObservationIgnored var onBegin: (() -> Void)?
    /// The whole transcription so far; the composer replaces what it inserted last time.
    @ObservationIgnored var onText: ((String) -> Void)?
    /// No more text will come.
    @ObservationIgnored var onEnd: (() -> Void)?

    @ObservationIgnored private var engine: DictationEngine?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var escapeMonitor: Any?
    @ObservationIgnored private var finishTimeout: Task<Void, Never>?

    /// For snapshots: draws the button as recording.
    init(previewPhase: Phase = .idle, previewLevel: Double = 0) {
        phase = previewPhase
        level = previewLevel
    }

    var isRecording: Bool { phase == .recording || phase == .starting }

    var problem: DictationProblem? {
        if case .unavailable(let problem) = phase { return problem }
        return nil
    }

    func toggle() {
        if isRecording { stop() } else { Task { await start() } }
    }

    func dismissProblem() {
        if problem != nil { phase = .idle }
    }

    func start() async {
        guard !isRecording else { return }
        tearDown(notify: true)
        if let problem = Self.buildProblem() {
            phase = .unavailable(problem)
            return
        }
        phase = .starting
        generation += 1
        let current = generation
        if let problem = await DictationPermissions.check() {
            if generation == current { phase = .unavailable(problem) }
            return
        }
        guard generation == current, phase == .starting else { return }
        onBegin?()
        do {
            let engine = try DictationEngine(locale: Locale.current)
            self.engine = engine
            try engine.start(
                onText: { [weak self] text, isFinal in
                    Task { @MainActor in self?.received(text, isFinal: isFinal, generation: current) }
                },
                onLevel: { [weak self] level in
                    Task { @MainActor in if self?.generation == current { self?.level = level } }
                },
                onEnd: { [weak self] message in
                    Task { @MainActor in self?.ended(message, generation: current) }
                })
            phase = .recording
            installEscapeMonitor()
        } catch let error as DictationEngine.Failure {
            tearDown(notify: true)
            phase = .unavailable(DictationProblem(message: error.message))
        } catch {
            tearDown(notify: true)
            phase = .unavailable(DictationProblem(message: "Dictation could not start: \(error.localizedDescription)"))
        }
    }

    /// Stops listening; the last words still being recognised are added before dictation ends.
    func stop() {
        guard isRecording else { return }
        phase = .idle
        level = 0
        removeEscapeMonitor()
        guard let engine else {
            tearDown(notify: true)
            return
        }
        engine.finish()
        let current = generation
        finishTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if self?.generation == current { self?.tearDown(notify: true) }
        }
    }

    /// Stops at once and drops anything not yet recognised (the message is being sent).
    func cancel() {
        let wasActive = isRecording || engine != nil
        if isRecording { phase = .idle }
        level = 0
        if wasActive { tearDown(notify: true) }
    }

    private func received(_ text: String, isFinal: Bool, generation current: Int) {
        guard generation == current, engine != nil else { return }
        onText?(text)
        if isFinal { tearDown(notify: true) }
    }

    private func ended(_ message: String?, generation current: Int) {
        guard generation == current else { return }
        let wasRecording = phase == .recording
        tearDown(notify: true)
        if wasRecording { phase = .idle }
        if let message, wasRecording { phase = .unavailable(DictationProblem(message: message)) }
    }

    private func tearDown(notify: Bool) {
        finishTimeout?.cancel()
        finishTimeout = nil
        removeEscapeMonitor()
        let hadEngine = engine != nil
        engine?.cancel()
        engine = nil
        generation += 1
        level = 0
        if notify, hadEngine { onEnd?() }
    }

    /// Esc stops dictation before anything else sees it (otherwise it would stop the agent).
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.keyCode == 53, modifiers.isEmpty else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isRecording else { return false }
                self.stop()
                return true
            }
            return handled ? nil : event
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    /// Microphone access needs the usage descriptions in Info.plist, and the audio input entitlement under the
    /// hardened runtime. Without them macOS would end the app or record silence, so the button explains instead.
    static func buildProblem() -> DictationProblem? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard info["NSMicrophoneUsageDescription"] != nil, info["NSSpeechRecognitionUsageDescription"] != nil else {
            return .notInThisBuild
        }
        if CodeSignature.hasHardenedRuntime, !CodeSignature.hasEntitlement("com.apple.security.device.audio-input") {
            return .notInThisBuild
        }
        return nil
    }
}

/// Asks for microphone and speech recognition access the first time, and reports a refusal.
enum DictationPermissions {
    static func check() async -> DictationProblem? {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { return .microphoneDenied }
        case .restricted: return .restricted
        default: return .microphoneDenied
        }
        switch await speechStatus() {
        case .authorized: return nil
        case .restricted: return .restricted
        default: return .speechDenied
        }
    }

    private nonisolated static func speechStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status) }
        }
    }
}

/// The audio and recognition work. Not on the main actor: the microphone tap and the recogniser call back on their
/// own threads, and only plain values cross back.
final class DictationEngine: @unchecked Sendable {
    struct Failure: Error {
        let message: String
    }

    private let recognizer: SFSpeechRecognizer
    private let audio = AVAudioEngine()
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    private var lastLevelTime: TimeInterval = 0

    init(locale: Locale) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer() else {
            throw Failure(message: "Speech recognition does not support \(locale.identifier).")
        }
        guard recognizer.isAvailable else {
            throw Failure(message: "Speech recognition is not available right now.")
        }
        self.recognizer = recognizer
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
    }

    var onDevice: Bool { request.requiresOnDeviceRecognition }

    func start(onText: @escaping @Sendable (String, Bool) -> Void, onLevel: @escaping @Sendable (Double) -> Void,
               onEnd: @escaping @Sendable (String?) -> Void) throws {
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw Failure(message: "No microphone is available.")
        }
        let request = self.request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            self?.report(level: Self.level(of: buffer), to: onLevel)
        }
        audio.prepare()
        do {
            try audio.start()
        } catch {
            input.removeTap(onBus: 0)
            throw Failure(message: "The microphone could not start: \(error.localizedDescription)")
        }
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                onText(result.bestTranscription.formattedString, result.isFinal)
                if result.isFinal { onEnd(nil) }
            } else if let error {
                let nsError = error as NSError
                // 216 and 301: the task was cancelled; 1110: no speech heard. Neither is worth a message.
                let quiet = [216, 301, 1110].contains(nsError.code)
                onEnd(quiet ? nil : "Dictation stopped: \(error.localizedDescription)")
            }
        }
        lock.withLock { self.task = task }
    }

    /// Stops the microphone; the recogniser finishes what it heard.
    func finish() {
        stopAudio()
        request.endAudio()
    }

    func cancel() {
        stopAudio()
        request.endAudio()
        lock.withLock { task }?.cancel()
    }

    private func stopAudio() {
        if audio.isRunning { audio.stop() }
        audio.inputNode.removeTap(onBus: 0)
    }

    private func report(level: Double, to onLevel: @Sendable (Double) -> Void) {
        let now = ProcessInfo.processInfo.systemUptime
        let due = lock.withLock { () -> Bool in
            guard now - lastLevelTime > 0.06 else { return false }
            lastLevelTime = now
            return true
        }
        if due { onLevel(level) }
    }

    /// Loudness of a buffer mapped to 0...1 (-50 dB and below is 0).
    private static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count { sum += data[index] * data[index] }
        let rms = (sum / Float(count)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_01))
        return Double(min(max((decibels + 50) / 50, 0), 1))
    }
}

/// Facts about the running app's code signature.
enum CodeSignature {
    static var hasHardenedRuntime: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let flags = dictionary[kSecCodeInfoFlags as String] as? UInt32 else { return false }
        return flags & SecCodeSignatureFlags.runtime.rawValue != 0
    }

    static func hasEntitlement(_ name: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, name as CFString, nil)
        return (value as? Bool) == true
    }
}

/// The composer's microphone button: plain when idle, filled with a level ring while recording.
struct DictationButton: View {
    let dictation: DictationController
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        let recording = dictation.isRecording
        Button {
            dictation.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(recording ? theme.danger.opacity(0.16) : (hovering ? theme.hover : .clear))
                if recording {
                    Circle()
                        .strokeBorder(theme.danger.opacity(0.35 + 0.65 * dictation.level), lineWidth: theme.z(1.5))
                        .scaleEffect(1 + 0.12 * dictation.level)
                }
                Image(systemName: recording ? "mic.fill" : "mic")
                    .font(theme.font(size: 13.5))
                    .foregroundStyle(recording ? theme.danger : theme.textSecondary)
            }
            .frame(width: theme.z(30), height: theme.z(30))
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.08), value: dictation.level)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(recording ? "Stop dictation (Esc)" : "Dictate")
        .accessibilityLabel(recording ? "Stop dictation" : "Dictate")
    }
}

/// Above the text when dictation cannot run: what is wrong and, when it helps, a button to the right Settings pane.
struct DictationProblemRow: View {
    let problem: DictationProblem
    let onDismiss: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.z(8)) {
            Image(systemName: "mic.slash")
                .font(theme.font(size: 11.5))
                .foregroundStyle(theme.warning)
            Text(problem.message)
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: theme.z(4))
            if let url = problem.settingsURL {
                Button("Open Settings") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.plain)
                    .font(theme.font(size: 12, weight: .medium))
                    .foregroundStyle(theme.accent)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(theme.font(size: 9, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, theme.z(10))
        .padding(.vertical, theme.z(7))
        .background(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).fill(theme.raisedFill))
    }
}
