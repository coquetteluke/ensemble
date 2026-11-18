import SwiftUI
import EnsembleKit

/// Settings > Customizations: the Customizations screen for the folder another screen asked for, else the selected
/// session's folder.
struct CustomizationsSettingsTab: View {
    @State private var model: CustomizationsModel
    private let focus = CustomizationsFocus.shared

    init(store: SessionStore) {
        _model = State(initialValue: CustomizationsModel(store: store))
    }

    var body: some View {
        CustomizationsView(model: model)
            .onAppear { model.pickDefaultFolder() }
            .onChange(of: focus.requestedFolder) {
                if focus.requestedFolder != nil { model.pickDefaultFolder() }
            }
    }
}
