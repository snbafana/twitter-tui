import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: ComposerModel
    var close: (() -> Void)?
    @FocusState private var clientIDFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(.system(.title2, design: .serif, weight: .semibold))
                Text("Add your X OAuth app credentials here, then log in from the composer.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                TextField("Client ID", text: $model.settings.clientID)
                    .textFieldStyle(.roundedBorder)
                    .focused($clientIDFocused)

                SecureField("Client Secret (optional)", text: $model.clientSecret)
                    .textFieldStyle(.roundedBorder)

                TextField("API base URL", text: $model.settings.baseURL)
                    .textFieldStyle(.roundedBorder)

                TextField("Callback URL", text: $model.settings.callbackURL)
                    .textFieldStyle(.roundedBorder)

                Text("Client secret and OAuth tokens are stored in Keychain. Client ID and endpoint settings are stored locally.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    close?()
                }

                Button("Done") {
                    model.saveSettings()
                    close?()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            clientIDFocused = true
        }
    }
}
