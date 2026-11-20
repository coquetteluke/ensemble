import SwiftUI
import AppKit
import Observation
import EnsembleKit

/// Remembers how the user pays for each model (`ModelAccessOption.id` by `ModelChoice.id`). Ids only, never a key.
enum ModelAccessMemory {
    private static let prefix = "modelPicker.access."

    static func remembered(_ choiceID: String) -> String? {
        UserDefaults.standard.string(forKey: prefix + choiceID)
    }

    static func remember(_ optionID: String, for choiceID: String) {
        UserDefaults.standard.set(optionID, forKey: prefix + choiceID)
    }
}

/// OpenCode's sign-in state by provider, for the picker's "sign-in or key" options. Loaded when the picker opens.
@MainActor @Observable
final class ModelPickerAccess {
    static let shared = ModelPickerAccess()
    private(set) var providers: [String: ModelProviderAccess] = [:]
    @ObservationIgnored private var loaded: Date?

    func load(store: SessionStore, force: Bool = false) async {
        if !force, let loaded, Date().timeIntervalSince(loaded) < 30 { return }
        guard let openCode = Self.openCode(store) else { return }
        loaded = Date()
        if let fresh = try? await openCode.modelProviderAccess() { providers = fresh }
    }

    static func openCode(_ store: SessionStore) -> OpenCodeClient? {
        (store.engine as? EngineRouter)?.engine(OpenCodeClient.self) ?? store.engine as? OpenCodeClient
    }
}

/// The composer's model picker, laid out like the reference app's model menu: the newest models of the session's
/// maker at the top (keys 1 to 9 pick them), that maker's Older models, a folder for every other maker, then Effort
/// and Fast mode. Picking a model that runs on a subscription and on an API key asks which, remembers the answer, and
/// asks for the key right there when none is saved yet. Search looks through every folder.
struct ModelPickerView: View {
    /// What the picker can do besides picking: pay options, key entry, effort and fast mode. Nil in the schedule
    /// editor, where a pick only sets the model.
    struct SessionContext {
        let store: SessionStore
        let session: SessionModel?
    }

    let models: [ModelInfo]
    let billing: [String: ModelBilling]?
    let current: ModelRef?
    let context: SessionContext?
    let onPick: (ModelRef) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @FocusState private var searchFocused: Bool
    @State private var query: String
    /// Open folders by maker id; "older:<maker id>" for a maker's Older models.
    @State private var open: Set<String>
    /// The model whose pay options are shown under it.
    @State private var optionsFor: String?
    /// The option whose key is being entered, with its model.
    @State private var keyEntry: KeyEntry?
    @State private var keyText = ""
    @State private var keyBusy = false
    @State private var keyProblem: String?
    @State private var access = ModelPickerAccess.shared

    struct KeyEntry: Equatable {
        var choiceID: String
        var option: ModelAccessOption
    }

    init(models: [ModelInfo], billing: [String: ModelBilling]?, current: ModelRef?, context: SessionContext?,
         initialQuery: String = "", initialOpen: Set<String> = [], initialOptionsFor: String? = nil,
         initialKeyEntry: KeyEntry? = nil, onPick: @escaping (ModelRef) -> Void) {
        self.models = models
        self.billing = billing
        self.current = current
        self.context = context
        self.onPick = onPick
        _query = State(initialValue: initialQuery)
        _open = State(initialValue: initialOpen)
        _optionsFor = State(initialValue: initialOptionsFor)
        _keyEntry = State(initialValue: initialKeyEntry)
    }

    var body: some View {
        let folders = ModelCatalog.folders(models, billing: billing)
        let top = ModelCatalog.topFolder(for: current, in: folders)
        VStack(alignment: .leading, spacing: 0) {
            // Do not auto-focus on appear so 1 to 9 shortcuts work immediately; once focused, digits type into search.
            InputField("Search models", text: $query, icon: "magnifyingglass", height: theme.z(28))
                .focused($searchFocused)
                .padding(theme.z(8))
            AdaptiveScroll(.vertical) {
                VStack(alignment: .leading, spacing: theme.z(1)) {
                    if searching {
                        results(ModelCatalog.search(query, in: folders), folders: folders)
                    } else if let top {
                        sectionTitle(top.maker.name)
                        ForEach(Array(top.current.enumerated()), id: \.element.id) { index, choice in
                            modelRow(choice, shortcut: index < 9 ? index + 1 : nil)
                        }
                        olderRow(top, indent: 0)
                        let others = folders.filter { $0.id != top.id }
                        if !others.isEmpty {
                            divider
                            ForEach(others) { folder in
                                folderRow(folder)
                            }
                        }
                    } else {
                        Text(models.isEmpty ? "No models. Add an API key in Settings." : "No models")
                            .font(theme.font(size: 12.5))
                            .foregroundStyle(theme.textTertiary)
                            .padding(theme.z(10))
                    }
                }
                .padding(.horizontal, theme.z(6))
                .padding(.bottom, theme.z(6))
            }
            .frame(maxHeight: theme.z(430))
            sessionControls
        }
        .frame(width: theme.z(320))
        .fixedSize(horizontal: false, vertical: true)
        .background(theme.popover)
        .task {
            guard !isSnapshot, let store = context?.store else { return }
            await access.load(store: store)
        }
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Width of the "..." column at the end of model rows.
    static let payColumn: CGFloat = 24
    /// Space from the end of a row to the number column: the row's padding, the gap and the "..." column. Counts and
    /// option checks end on the same line as the numbers.
    static let trailingColumn: CGFloat = 8 + 2 + payColumn

    // MARK: Sections

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(theme.font(size: 11, weight: .semibold))
            .foregroundStyle(theme.textTertiary)
            .padding(.horizontal, theme.z(10))
            .padding(.top, theme.z(4))
            .padding(.bottom, theme.z(3))
    }

    private var divider: some View {
        HLine(color: theme.border)
            .padding(.vertical, theme.z(5))
            .padding(.horizontal, theme.z(6))
    }

    @ViewBuilder private func results(_ found: [ModelChoice], folders: [ModelFolder]) -> some View {
        if found.isEmpty {
            Text("No matches")
                .font(theme.font(size: 12.5))
                .foregroundStyle(theme.textTertiary)
                .padding(theme.z(10))
        } else {
            ForEach(folders.filter { folder in found.contains { $0.maker == folder.maker } }) { folder in
                sectionTitle(folder.maker.name)
                ForEach(found.filter { $0.maker == folder.maker }) { choice in
                    modelRow(choice, shortcut: nil)
                }
            }
        }
    }

    /// A maker's folder: its newest models, then its Older models, shown when open.
    @ViewBuilder private func folderRow(_ folder: ModelFolder) -> some View {
        let isOpen = open.contains(folder.id)
        let holdsCurrent = current.map { ref in folder.all.contains { $0.contains(ref) } } ?? false
        disclosureRow(title: folder.maker.name, symbol: "folder", count: folder.all.count, isOpen: isOpen, indent: 0,
                      holdsCurrent: holdsCurrent && !isOpen) {
            toggle(folder.id)
        }
        if isOpen {
            VStack(alignment: .leading, spacing: theme.z(1)) {
                ForEach(folder.current) { choice in
                    modelRow(choice, shortcut: nil)
                }
                olderRow(folder, indent: 1)
            }
            .padding(.leading, theme.z(14))
        }
    }

    @ViewBuilder private func olderRow(_ folder: ModelFolder, indent: Int) -> some View {
        if !folder.older.isEmpty {
            let key = "older:\(folder.id)"
            let isOpen = open.contains(key)
            disclosureRow(title: "Older models", symbol: nil, count: folder.older.count, isOpen: isOpen, indent: indent) {
                toggle(key)
            }
            if isOpen {
                VStack(alignment: .leading, spacing: theme.z(1)) {
                    ForEach(folder.older) { choice in
                        modelRow(choice, shortcut: nil)
                    }
                }
                .padding(.leading, theme.z(14))
            }
        }
    }

    /// `holdsCurrent` marks a closed folder that has the current model inside, so it can be found.
    private func disclosureRow(title: String, symbol: String?, count: Int, isOpen: Bool, indent: Int,
                               holdsCurrent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: theme.z(8)) {
                Image(systemName: "chevron.right")
                    .font(theme.font(size: 9, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: theme.z(10))
                if let symbol {
                    Image(systemName: symbol)
                        .font(theme.font(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
                Text(title)
                    .font(theme.font(size: 13))
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: theme.z(8))
                if holdsCurrent {
                    Image(systemName: "checkmark")
                        .font(theme.font(size: 11, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
                Text("\(count)")
                    .font(theme.font(size: 11.5))
                    .foregroundStyle(theme.textTertiary)
                    .monospacedDigit()
            }
            .padding(.leading, theme.z(10))
            .padding(.trailing, theme.z(Self.trailingColumn))
            .frame(height: theme.z(30))
        }
        .buttonStyle(RowButtonStyle(raised: true))
        .accessibilityLabel(title)
        .accessibilityValue((isOpen ? "Open, \(count) models" : "Closed, \(count) models") + (holdsCurrent ? ", has the current model" : ""))
    }

    private func toggle(_ key: String) {
        if open.contains(key) { open.remove(key) } else { open.insert(key) }
    }

    // MARK: Model rows

    private func options(_ choice: ModelChoice) -> [ModelAccessOption] {
        guard let store = context?.store else {
            return choice.routes.map { ModelAccessOption(id: $0.ref.providerID, billing: $0.billing, title: $0.providerName, ref: $0.ref,
                                                         available: $0.available) }
        }
        return ModelAccess.options(for: choice, providers: store.providers, access: access.providers)
    }

    @ViewBuilder private func modelRow(_ choice: ModelChoice, shortcut: Int?) -> some View {
        let options = options(choice)
        let selected = choice.contains(current)
        let currentOption = selected ? ModelAccess.current(options, ref: current, access: access.providers) : nil
        let usable = options.contains { $0.isReady || ($0.available && $0.missingKey != nil) }
        let several = context != nil && options.count > 1
        VStack(alignment: .leading, spacing: 0) {
            ModelPickerRow(
                name: choice.name,
                note: note(choice, selected: selected, current: currentOption, several: several, usable: usable),
                context: choice.contextLimit.map { Format.tokens($0) },
                selected: selected, usable: usable, shortcut: shortcut,
                digitShortcut: searchFocused || searching || keyEntry != nil ? nil : shortcut,
                payButton: several, payOpen: optionsFor == choice.id,
                help: helpText(choice),
                onPick: { pick(choice, options: options) },
                onPay: { withAnimation(.easeOut(duration: 0.15)) { optionsFor = optionsFor == choice.id ? nil : choice.id } })
            if optionsFor == choice.id, context != nil {
                optionRows(choice, options: options, current: currentOption)
            }
        }
    }

    /// Under the name, only when it matters: how the selected model is paid for, "Free", or "Not set up".
    private func note(_ choice: ModelChoice, selected: Bool, current: ModelAccessOption?, several: Bool, usable: Bool) -> String? {
        if !usable { return "Not set up" }
        if selected, several, let current { return current.title }
        if let route = choice.primary, route.billing == .free, choice.routes.allSatisfy({ $0.billing == .free }) { return "Free" }
        return nil
    }

    private func helpText(_ choice: ModelChoice) -> String {
        var parts = [choice.name]
        if let limit = choice.contextLimit { parts.append("\(Format.tokens(limit)) context") }
        parts.append(contentsOf: choice.routes.map(\.providerName))
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private func optionRows(_ choice: ModelChoice, options: [ModelAccessOption], current: ModelAccessOption?) -> some View {
        VStack(alignment: .leading, spacing: theme.z(1)) {
            ForEach(options) { option in
                if keyEntry?.choiceID == choice.id, keyEntry?.option.id == option.id, let target = option.missingKey {
                    keyForm(choice, option: option, target: target)
                } else {
                    optionRow(choice, option: option, isCurrent: current?.id == option.id)
                }
            }
        }
        .padding(.leading, theme.z(18))
        .padding(.trailing, theme.z(Self.trailingColumn - 8))
        .padding(.bottom, theme.z(4))
    }

    private func optionRow(_ choice: ModelChoice, option: ModelAccessOption, isCurrent: Bool) -> some View {
        Button {
            choose(option, for: choice)
        } label: {
            HStack(spacing: theme.z(8)) {
                Image(systemName: symbol(option.billing))
                    .font(theme.font(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: theme.z(16))
                Text(option.title)
                    .font(theme.font(size: 12.5))
                    .foregroundStyle(option.available ? theme.textPrimary : theme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: theme.z(6))
                if !option.available {
                    Text("Not signed in")
                        .font(theme.font(size: 11))
                        .foregroundStyle(theme.textTertiary)
                } else if option.missingKey != nil {
                    Text("Add key")
                        .font(theme.font(size: 11, weight: .medium))
                        .foregroundStyle(theme.accent)
                } else if isCurrent {
                    Image(systemName: "checkmark")
                        .font(theme.font(size: 10.5, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
            }
            .padding(.horizontal, theme.z(8))
            .frame(height: theme.z(26))
        }
        .buttonStyle(RowButtonStyle(raised: true))
        .disabled(!option.available)
    }

    private func symbol(_ billing: ModelBilling) -> String {
        switch billing {
        case .subscription: "person.crop.circle"
        case .apiKey: "key"
        case .free: "gift"
        case .local: "laptopcomputer"
        }
    }

    /// The key field, in place under the option: saved to the Keychain (Claude) or to OpenCode, then cleared.
    private func keyForm(_ choice: ModelChoice, option: ModelAccessOption, target: ModelKeyTarget) -> some View {
        VStack(alignment: .leading, spacing: theme.z(6)) {
            HStack(spacing: theme.z(8)) {
                Image(systemName: "key")
                    .font(theme.font(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: theme.z(16))
                Text(target.title)
                    .font(theme.font(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
            }
            InputField("Paste your key", text: $keyText, secure: true, height: theme.z(28))
                .onSubmit { saveKey(choice, option: option, target: target) }
            Text(target.storage == .keychain ? "Saved in your login Keychain, used only by Claude agents set to this key."
                 : "Saved in OpenCode's credential store.")
                .font(theme.font(size: 11))
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let keyProblem {
                Text(keyProblem)
                    .font(theme.font(size: 11))
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: theme.z(8)) {
                Spacer(minLength: 0)
                Button("Cancel") {
                    keyText = ""
                    keyProblem = nil
                    keyEntry = nil
                }
                .buttonStyle(SecondaryButtonStyle())
                Button(keyBusy ? "Saving" : "Save and use") { saveKey(choice, option: option, target: target) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || keyBusy)
            }
        }
        .padding(theme.z(8))
        .background(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).fill(theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: theme.z(8), style: .continuous).strokeBorder(theme.border, lineWidth: 1))
        .padding(.vertical, theme.z(2))
    }

    // MARK: Choosing

    /// A click on a model: the remembered (or only) way to pay is used at once; otherwise its options open.
    private func pick(_ choice: ModelChoice, options: [ModelAccessOption]) {
        guard context != nil else {
            if let ref = (choice.routes.first(where: \.available) ?? choice.primary)?.ref { onPick(ref) }
            return
        }
        if let option = ModelAccess.automatic(options, remembered: ModelAccessMemory.remembered(choice.id)) {
            choose(option, for: choice)
        } else {
            withAnimation(.easeOut(duration: 0.15)) { optionsFor = choice.id }
        }
    }

    private func choose(_ option: ModelAccessOption, for choice: ModelChoice) {
        if option.missingKey != nil {
            keyText = ""
            keyProblem = nil
            keyEntry = KeyEntry(choiceID: choice.id, option: option)
            return
        }
        guard let ref = option.ref, option.available else { return }
        ModelAccessMemory.remember(option.id, for: choice.id)
        let picked = ref
        if let method = option.credential, let store = context?.store, let openCode = ModelPickerAccess.openCode(store) {
            Task {
                do {
                    try await openCode.activateCredential(integrationID: ref.providerID, method: method)
                    await access.load(store: store, force: true)
                    await store.refreshProviders()
                } catch {
                    store.lastError = "Could not switch to \(option.title): \(error.localizedDescription)"
                    return
                }
                onPick(picked)
            }
        } else {
            onPick(picked)
        }
    }

    private func saveKey(_ choice: ModelChoice, option: ModelAccessOption, target: ModelKeyTarget) {
        let typed = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !keyBusy, let store = context?.store else { return }
        keyText = ""
        keyBusy = true
        keyProblem = nil
        Task {
            defer { keyBusy = false }
            do {
                try await store.setAPIKey(providerID: target.providerID, key: typed)
            } catch {
                keyProblem = "The key was not saved: \(error.localizedDescription)"
                return
            }
            await access.load(store: store, force: true)
            keyEntry = nil
            // The engines list the key's models now; find this model among them.
            let ref = option.ref
                ?? ModelCatalog.folders(store.models, billing: billing).flatMap(\.all).first { $0.id == choice.id }?
                    .routes.first { $0.ref.providerID == target.providerID }?.ref
            guard let ref else {
                keyProblem = "Key saved. \(choice.name) is not offered with this key; the \(choice.maker.name) folder lists the models that are."
                return
            }
            // Once the key is saved the model is an ordinary route of the key's provider, listed under its own id.
            ModelAccessMemory.remember(option.ref == nil ? ref.providerID : option.id, for: choice.id)
            onPick(ref)
        }
    }

    // MARK: Effort and fast mode

    @ViewBuilder private var sessionControls: some View {
        if let store = context?.store, let session = context?.session, !searching {
            let options = store.options(for: session.info.model)
            let levels = options?.effortLevels ?? []
            let fast = options?.supportsFastMode == true
            if !levels.isEmpty || fast {
                HLine(color: theme.border)
                VStack(alignment: .leading, spacing: theme.z(1)) {
                    if !levels.isEmpty {
                        effortRow(store: store, session: session, levels: levels, defaultLevel: options?.defaultEffort)
                    }
                    if fast {
                        fastRow(store: store, session: session)
                    }
                }
                .padding(theme.z(6))
            }
        }
    }

    private func effortRow(store: SessionStore, session: SessionModel, levels: [EffortLevel], defaultLevel: EffortLevel?) -> some View {
        let current = session.effort ?? defaultLevel
        return HStack(spacing: theme.z(8)) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(theme.font(size: 12))
                .foregroundStyle(theme.textSecondary)
                .frame(width: theme.z(16))
            Text("Effort")
                .font(theme.font(size: 13))
                .foregroundStyle(theme.textPrimary)
            Spacer(minLength: theme.z(8))
            if isSnapshot {
                effortLabel(current)
            } else {
                Menu {
                    ForEach(levels, id: \.self) { level in
                        Button {
                            Task { await store.setEffort(level, for: session.id) }
                        } label: {
                            if level == current { Label(level.label, systemImage: "checkmark") } else { Text(level.label) }
                        }
                    }
                } label: {
                    effortLabel(current)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Effort")
                .accessibilityValue(current?.label ?? "Default")
            }
        }
        .padding(.horizontal, theme.z(10))
        .frame(height: theme.z(30))
    }

    private func effortLabel(_ level: EffortLevel?) -> some View {
        HStack(spacing: theme.z(4)) {
            Text(level?.label ?? "Default")
                .font(theme.font(size: 12.5))
            Image(systemName: "chevron.up.chevron.down")
                .font(theme.font(size: 8.5, weight: .semibold))
        }
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, theme.z(8))
        .frame(height: theme.z(24))
        .background(RoundedRectangle(cornerRadius: theme.z(6), style: .continuous).fill(theme.raisedFill))
    }

    private func fastRow(store: SessionStore, session: SessionModel) -> some View {
        HStack(spacing: theme.z(8)) {
            Image(systemName: session.fastMode ? "bolt.fill" : "bolt")
                .font(theme.font(size: 12))
                .foregroundStyle(session.fastMode ? theme.accent : theme.textSecondary)
                .frame(width: theme.z(16))
            Text("Fast mode")
                .font(theme.font(size: 13))
                .foregroundStyle(theme.textPrimary)
            Spacer(minLength: theme.z(8))
            if isSnapshot {
                // Switches are platform views, which snapshots cannot draw.
                Capsule()
                    .fill(session.fastMode ? theme.accent : theme.textTertiary.opacity(0.35))
                    .frame(width: theme.z(26), height: theme.z(15))
                    .overlay(alignment: session.fastMode ? .trailing : .leading) {
                        Circle().fill(Color.white).padding(theme.z(1.5))
                    }
            } else {
                Toggle("Fast mode", isOn: Binding(get: { session.fastMode },
                                                  set: { on in Task { await store.setFastMode(on, for: session.id) } }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .tint(theme.accent)
            }
        }
        .padding(.horizontal, theme.z(10))
        .frame(height: theme.z(30))
    }
}

/// One model: its name (and a short note), the context window, a check when selected and its number key. The "..."
/// button for how to pay shows on hover, on the selected model and while its options are open.
private struct ModelPickerRow: View {
    let name: String
    let note: String?
    let context: String?
    let selected: Bool
    let usable: Bool
    let shortcut: Int?
    let digitShortcut: Int?
    let payButton: Bool
    let payOpen: Bool
    let help: String
    let onPick: () -> Void
    let onPay: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: theme.z(2)) {
            Button(action: onPick) {
                HStack(spacing: theme.z(8)) {
                    VStack(alignment: .leading, spacing: theme.z(1)) {
                        Text(name)
                            .font(theme.font(size: 13))
                            .foregroundStyle(usable ? theme.textPrimary : theme.textTertiary)
                            .lineLimit(1)
                        if let note {
                            Text(note)
                                .font(theme.font(size: 11))
                                .foregroundStyle(theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: theme.z(6))
                    if let context {
                        Text(context)
                            .font(theme.font(size: 11.5))
                            .foregroundStyle(theme.textTertiary)
                            .monospacedDigit()
                    }
                    Image(systemName: "checkmark")
                        .font(theme.font(size: 11, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .opacity(selected ? 1 : 0)
                        .frame(width: theme.z(12))
                    // The number column is kept on every row so the context sizes line up.
                    Text(shortcut.map { "\($0)" } ?? "")
                        .font(theme.font(size: 11.5))
                        .foregroundStyle(theme.textTertiary)
                        .monospacedDigit()
                        .frame(width: theme.z(9), alignment: .trailing)
                }
                .padding(.leading, theme.z(10))
                .padding(.trailing, theme.z(8))
                .frame(minHeight: theme.z(30))
                .padding(.vertical, theme.z(note == nil ? 0 : 3))
            }
            .buttonStyle(RowButtonStyle(raised: true))
            .disabled(!usable)
            .modifier(DigitShortcut(digit: digitShortcut))
            .help(help)
            .accessibilityAddTraits(selected ? .isSelected : [])
            if payButton {
                Button(action: onPay) {
                    Image(systemName: "ellipsis")
                        .font(theme.font(size: 11, weight: .semibold))
                        .foregroundStyle(payOpen ? theme.textPrimary : theme.textTertiary)
                        .frame(width: theme.z(ModelPickerView.payColumn), height: theme.z(24))
                }
                .buttonStyle(RowButtonStyle(selected: payOpen, cornerRadius: theme.z(6), raised: true))
                .opacity(hovering || selected || payOpen ? 1 : 0)
                .help("How to pay for \(name)")
                .accessibilityLabel("How to pay for \(name)")
            } else {
                Color.clear.frame(width: theme.z(ModelPickerView.payColumn), height: theme.z(24))
            }
        }
        .onHover { hovering = $0 }
    }
}

/// Keys 1 to 9 pick the top models, like the reference app's menu.
private struct DigitShortcut: ViewModifier {
    let digit: Int?

    func body(content: Content) -> some View {
        if let digit, let character = String(digit).first {
            content.keyboardShortcut(KeyEquivalent(character), modifiers: [])
        } else {
            content
        }
    }
}
