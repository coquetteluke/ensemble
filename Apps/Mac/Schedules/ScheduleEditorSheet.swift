import SwiftUI
import AppKit
import EnsembleKit

/// New or edited scheduled task: name, prompt, where it runs (a new session in a folder with a model, or one session),
/// permission mode (Ask by default; Bypass only after its warning is confirmed), the trigger card, catch-up and keep
/// awake.
struct ScheduleEditorSheet: View {
    let store: SessionStore
    let request: ScheduleEditorRequest
    let onSave: (ScheduledTask) -> Void
    /// Snapshots pass a fixed time for the trigger preview.
    var now: Date?
    /// Snapshots pass a fixed trust line; the app asks the store.
    var trustLineOverride: NewSessionTrustLine??

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var draft: ScheduledTask
    @State private var bypassConfirmed: Bool
    @State private var billing: [String: ModelBilling]?

    init(store: SessionStore, request: ScheduleEditorRequest, now: Date? = nil, trustLineOverride: NewSessionTrustLine?? = nil,
         bypassConfirmed: Bool? = nil, onSave: @escaping (ScheduledTask) -> Void) {
        self.store = store
        self.request = request
        self.now = now
        self.trustLineOverride = trustLineOverride
        self.onSave = onSave
        _draft = State(initialValue: request.task)
        _bypassConfirmed = State(initialValue: bypassConfirmed ?? (!request.isNew && request.task.permissionMode == .bypass))
    }

    private enum Target: Hashable { case newSession, oneSession }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(request.isNew ? "New scheduled task" : "Edit scheduled task")
                .font(theme.font(size: 15, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, theme.z(22))
                .padding(.top, theme.z(20))
                .padding(.bottom, theme.z(14))
            AdaptiveScroll(.vertical) {
                VStack(alignment: .leading, spacing: theme.z(16)) {
                    field("Name") {
                        InputField("Morning triage", text: $draft.name, height: 30)
                    }
                    field("Prompt") {
                        SchedulePromptEditor(text: $draft.prompt, placeholder: "What the agent does each time it runs")
                    }
                    field("Runs in") {
                        ScheduleSegmented(options: [(Target.newSession, "A new session each time"), (Target.oneSession, "One session")],
                                          selection: targetBinding)
                    }
                    if draft.continueSessionID == nil {
                        field("Folder") { folderPicker }
                        field("Model") { modelChip }
                    } else {
                        field("Session") { sessionChip }
                    }
                    if let line = trustLine {
                        NewSessionTrustRow(line: line, error: store.trustError(for: trustDirectory)) {
                            store.trustFolder(trustDirectory)
                        }
                    }
                    field("Permissions") { modeChip }
                    if draft.permissionMode == .bypass { bypassWarning }
                    field("When") { ScheduleTriggerCard(trigger: $draft.trigger, now: now) }
                    field("Missed runs") {
                        HStack(spacing: theme.z(10)) {
                            catchUpChip
                            Text(draft.catchUpWindow < 1 ? "A run missed while the Mac sleeps or Ensemble is closed is skipped."
                                 : "A run missed while the Mac sleeps or Ensemble is closed runs once when it is back.")
                                .font(theme.font(size: 11.5))
                                .foregroundStyle(theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Toggle(isOn: $draft.keepAwake) {
                        VStack(alignment: .leading, spacing: theme.z(2)) {
                            Text("Keep the Mac awake while it runs")
                                .font(theme.font(size: 13))
                                .foregroundStyle(theme.textPrimary)
                            Text("Ensemble never wakes a sleeping Mac to run a task.")
                                .font(theme.font(size: 11.5))
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                    .toggleStyle(CompactSwitchStyle())
                }
                .padding(.horizontal, theme.z(22))
                .padding(.bottom, theme.z(16))
            }
            .frame(height: isSnapshot ? nil : theme.z(560))
            HLine()
            footer
        }
        .frame(width: theme.z(580))
        .background(theme.background)
        .task {
            guard !isSnapshot, let source = store.engine as? any EngineModelBilling else { return }
            billing = try? await source.modelBilling()
        }
    }

    // MARK: Fields

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: theme.z(7)) {
            Text(label)
                .font(theme.font(size: 12, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            content()
        }
    }

    private var targetBinding: Binding<Target> {
        Binding(get: { draft.continueSessionID == nil ? .newSession : .oneSession }, set: { target in
            switch target {
            case .newSession:
                draft.continueSessionID = nil
            case .oneSession:
                if draft.continueSessionID == nil {
                    draft.continueSessionID = sessionChoices.first { $0.directory == draft.directory }?.id ?? sessionChoices.first?.id ?? ""
                }
            }
        })
    }

    private var folderPicker: some View {
        VStack(alignment: .leading, spacing: theme.z(8)) {
            HStack(spacing: theme.z(8)) {
                HStack(spacing: theme.z(8)) {
                    Image(systemName: "folder")
                        .font(theme.font(size: 12))
                        .foregroundStyle(theme.textSecondary)
                    Text(draft.directory.isEmpty ? "Choose a project folder" : Format.abbreviatedPath(draft.directory))
                        .font(theme.font(size: 13))
                        .foregroundStyle(draft.directory.isEmpty ? theme.textTertiary : theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, theme.z(10))
                .frame(height: theme.z(30))
                .background(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).fill(theme.elevated))
                .overlay(RoundedRectangle(cornerRadius: theme.z(7), style: .continuous).strokeBorder(theme.border))
                Button("Choose...", action: chooseFolder)
                    .buttonStyle(SecondaryButtonStyle())
            }
            let recent = store.projects.map(\.directory).prefix(4)
            if !recent.isEmpty {
                HStack(spacing: theme.z(6)) {
                    ForEach(Array(recent), id: \.self) { folder in
                        Button(Format.folderName(folder)) { draft.directory = folder }
                            .buttonStyle(.plain)
                            .font(theme.font(size: 12))
                            .foregroundStyle(draft.directory == folder ? theme.textPrimary : theme.textSecondary)
                            .padding(.horizontal, theme.z(8))
                            .frame(height: theme.z(24))
                            .background(RoundedRectangle(cornerRadius: theme.z(6)).fill(draft.directory == folder ? theme.selection : theme.hover))
                            .help(folder)
                    }
                }
            }
        }
    }

    private var modelChip: some View {
        ScheduleChip(symbol: "cpu", text: store.modelName(draft.model)) { dismiss in
            ModelMenuContent(models: store.models, current: draft.model, billing: billing) { ref in
                draft.model = ref
                dismiss()
            }
        }
    }

    private var sessionChoices: [SessionModel] { Array(store.sidebarOrder.prefix(40)) }

    private var sessionChip: some View {
        let current = draft.continueSessionID.flatMap { store.session($0) }
        return ScheduleChip(symbol: "bubble.left", text: current?.title ?? "Choose a session") { dismiss in
            ScheduleChoiceList(width: 360) {
                if sessionChoices.isEmpty {
                    Text("No sessions yet")
                        .font(theme.font(size: 12.5))
                        .foregroundStyle(theme.textTertiary)
                        .padding(theme.z(10))
                }
                AdaptiveScroll(.vertical) {
                    VStack(alignment: .leading, spacing: theme.z(2)) {
                        ForEach(sessionChoices) { session in
                            ScheduleChoiceRow(title: session.title, detail: "\(Format.folderName(session.directory))  \u{00B7}  \(store.modelName(session.info.model))",
                                              selected: session.id == draft.continueSessionID) {
                                draft.continueSessionID = session.id
                                dismiss()
                            }
                        }
                    }
                }
                .frame(maxHeight: theme.z(360))
            }
        }
    }

    private var modeChip: some View {
        let mode = draft.permissionMode
        return ScheduleChip(symbol: mode.symbolName, text: mode.label, tint: mode.isDangerous ? theme.danger : nil) { dismiss in
            ScheduleChoiceList {
                ForEach(ScheduledTask.permissionModes, id: \.self) { option in
                    ScheduleChoiceRow(title: option.label, detail: option.summary, symbol: option.symbolName,
                                      selected: option == mode, tint: option.isDangerous ? theme.danger : nil) {
                        draft.permissionMode = option
                        dismiss()
                    }
                }
            }
        }
    }

    private var bypassWarning: some View {
        VStack(alignment: .leading, spacing: theme.z(8)) {
            HStack(alignment: .top, spacing: theme.z(8)) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.danger)
                Text("Bypass runs every command and file edit without asking, with nobody watching. Use it only in a folder "
                     + "you can restore from git or a backup.")
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: $bypassConfirmed) {
                Text("I understand, run this task in Bypass")
                    .font(theme.font(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.danger)
            }
            .toggleStyle(CompactSwitchStyle())
        }
        .padding(theme.z(12))
        .background(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).fill(theme.danger.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).strokeBorder(theme.danger.opacity(0.45)))
    }

    private var catchUpChip: some View {
        ScheduleChip(symbol: "arrow.clockwise", text: ScheduledTask.catchUpLabel(draft.catchUpWindow)) { dismiss in
            ScheduleChoiceList(width: 220) {
                ForEach(ScheduledTask.catchUpChoices, id: \.self) { window in
                    ScheduleChoiceRow(title: window < 1 ? "Never catch up" : "Catch up " + ScheduledTask.catchUpLabel(window).lowercased(),
                                      selected: abs(window - draft.catchUpWindow) < 1) {
                        draft.catchUpWindow = window
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: Trust

    private var trustDirectory: String {
        draft.continueSessionID.flatMap { store.session($0)?.directory } ?? draft.directory
    }

    private var trustLine: NewSessionTrustLine? {
        if let trustLineOverride { return trustLineOverride }
        let model = draft.continueSessionID.flatMap { store.session($0)?.info.model } ?? draft.model
        return store.newSessionTrustLine(directory: trustDirectory, model: model)
    }

    // MARK: Footer

    private var problem: String? {
        if draft.continueSessionID == "" { return "Choose a session." }
        if let id = draft.continueSessionID, store.session(id) == nil { return "The session it continues was deleted. Choose another." }
        if let error = draft.validationError(now: now ?? Date()) { return error }
        if draft.permissionMode == .bypass, !bypassConfirmed { return "Confirm Bypass above, or choose another mode." }
        return nil
    }

    private var footer: some View {
        HStack(spacing: theme.z(10)) {
            if let problem, showsProblem {
                Text(problem)
                    .font(theme.font(size: 12))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: theme.z(8))
            Button("Cancel") { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button(request.isNew ? "Create task" : "Save") { save() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
        }
        .padding(.horizontal, theme.z(22))
        .padding(.vertical, theme.z(14))
    }

    /// A new task's empty name and prompt are not called out before anything is typed, and the trigger card shows its own
    /// error.
    private var showsProblem: Bool {
        guard problem != draft.trigger.validationError(now: now ?? Date()) else { return false }
        return !request.isNew || !draft.name.isEmpty || !draft.prompt.isEmpty
    }

    private func save() {
        guard problem == nil else { return }
        var task = draft
        task.name = task.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .custom(let cron) = task.trigger { task.trigger = .custom(cron: cron.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let id = task.continueSessionID, let session = store.session(id) {
            task.directory = session.directory
            task.model = session.info.model
        }
        onSave(task)
        dismiss()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if !draft.directory.isEmpty { panel.directoryURL = URL(fileURLWithPath: draft.directory) }
        if panel.runModal() == .OK, let url = panel.url { draft.directory = url.path }
    }
}
